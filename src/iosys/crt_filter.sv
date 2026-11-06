// Centered three-tap horizontal blur, after scaling and before OSD composition.
// Blur uses three compensated stages: palette RGB, center history, and FIR
// result. The caller prefetches three pixels. Bypass retains its original read address and
// rgb_in passes straight through, including during live framebuffer writes.
// Scanline alone uses palette_q and requires one pixel of caller prefetch.
module crt_filter (
    input wire pclk, resetn,
    input wire [23:0] rgb_in,
    input wire first_pixel, last_pixel,
    input wire [3:0] scan_depth, // 0..8 attenuation in sixteenths, from native row phase.
    input wire [31:0] config_active,
    output wire [23:0] rgb_out
);
    reg [23:0] palette_q=0, center=0, previous=0;
    always @(posedge pclk) begin
        if (!resetn) begin palette_q<=0;center<=0;previous<=0;end
        else begin palette_q<=rgb_in;center<=palette_q;previous<=center;end
    end
    wire [23:0] left=first_pixel?center:previous;
    wire [23:0] right=last_pixel?center:palette_q;
    function automatic [7:0] channel;
        input [7:0] l,c,r;
        input [1:0] strength;
        reg [11:0] total,weighted_center;
        reg [8:0] neighbors;
        reg [9:0] rounded_neighbors;
        begin
            total=0;weighted_center=0;rounded_neighbors=0;
            neighbors={1'b0,l}+{1'b0,r};
            // Blend the base [1,2,1]/4 kernel by 1/4, 1/2, or 1.
            // Round to nearest (half up); no gamma conversion in this stage.
            case(strength)
                1: begin
                    weighted_center=({4'b0,c}<<4)-({4'b0,c}<<1);
                    rounded_neighbors={1'b0,neighbors}+10'd8;
                    total=weighted_center+{2'b0,rounded_neighbors};channel=total[11:4];
                end
                2: begin
                    weighted_center=({4'b0,c}<<2)+({4'b0,c}<<1);
                    rounded_neighbors={1'b0,neighbors}+10'd4;
                    total=weighted_center+{2'b0,rounded_neighbors};channel=total[10:3];
                end
                3: begin
                    weighted_center={4'b0,c}<<1;
                    rounded_neighbors={1'b0,neighbors}+10'd2;
                    total=weighted_center+{2'b0,rounded_neighbors};channel=total[9:2];
                end
                default: channel=c;
            endcase
        end
    endfunction
    wire [1:0] strength=config_active[16]?config_active[18:17]:2'b00;
    wire [23:0] blurred=strength==0?rgb_in:
                   {channel(left[23:16],center[23:16],right[23:16],strength),
                    channel(left[15:8],center[15:8],right[15:8],strength),
                    channel(left[7:0],center[7:0],right[7:0],strength)};
    // Split palette/blur from gain so that they meet the pixel clock.
    // Use the result register for every enabled blur, including scanline OFF.
    // This eliminates the long unregistered FIR path to final RGB.
    reg [23:0] blurred_q=0;
    always @(posedge pclk)begin
        if(!resetn)blurred_q<=0;else blurred_q<=blurred;
    end
    // Keep the unregistered blur path completely outside the gain arithmetic.
    // Selecting it before gain would leave a long (mode-incompatible) STA path.
    wire [23:0] scan_input=strength!=0?blurred_q:palette_q;
    function automatic [7:0] dim_channel;
        input [7:0] c;
        input [3:0] depth;
        reg [4:0] gain;
        reg [12:0] total;
        begin
            gain=5'd16-{1'b0,depth};
            total=c*gain+13'd8;
            dim_channel=total[11:4];
        end
    endfunction
    wire scan_enabled=config_active[16] && |config_active[20:19];
    wire [23:0] scanned={dim_channel(scan_input[23:16],scan_depth),
                    dim_channel(scan_input[15:8],scan_depth),
                    dim_channel(scan_input[7:0],scan_depth)};
    // Raw palette RGB never passes through the gain arithmetic. Master OFF
    // retains the exact legacy read timing; registered effect paths are compensated.
    assign rgb_out=scan_enabled?scanned:strength!=0?blurred_q:rgb_in;
endmodule
