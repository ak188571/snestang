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
    // Frame-applied core_config[21]: brightness-dependent scanline depth.
    // Use the source pixel at the FIR center. Capture its brightness class
    // alongside blurred_q (or palette_q when blur is disabled).
    wire [23:0] beam_pixel = strength != 0 ? center : rgb_in;
    wire [3:0] luma = {2'b0, beam_pixel[23:22]} +
                      {1'b0, beam_pixel[15:14], 1'b0} +
                      {2'b0, beam_pixel[7:6]};
    reg [1:0] beam_class = 0;
    always @(posedge pclk) begin
        if (!resetn) beam_class <= 0;
        else beam_class <= luma[3:2];
    end
    // Middle band retains about 3/4 of the depth, highlights retain 1/2.
    wire [3:0] middle_depth = scan_depth - (({1'b0, scan_depth} + 5'd2) >> 2);
    wire [3:0] beam_depth = !config_active[21] ? scan_depth :
                            beam_class[1] ? (scan_depth >> 1) :
                            beam_class[0] ? middle_depth : scan_depth;
    wire [23:0] scanned={dim_channel(scan_input[23:16],beam_depth),
                    dim_channel(scan_input[15:8],beam_depth),
                    dim_channel(scan_input[7:0],beam_depth)};
    // Raw palette RGB never passes through the gain arithmetic. Master OFF
    // retains the exact legacy read timing; registered effect paths are compensated.
    assign rgb_out=scan_enabled?scanned:strength!=0?blurred_q:rgb_in;
endmodule

// The RGB input is the converter's existing registered composite pixel.
// Register its per-channel mask in parallel, so no pixel delay is added.
module crt_phosphor_mask (
    input wire pclk, resetn,
    input wire before_first, odd_row, game_pixel,
    input wire [1:0] mode, gamma_mode,
    input wire [23:0] game_rgb,
    input wire [23:0] composed_rgb,
    output wire [23:0] rgb_out
);
    // One-hot RGB order. Restart the pattern at the game's left edge on every row.
    reg [2:0] stripe = 3'b100;
    always @(posedge pclk) begin
        if (!resetn || before_first) stripe <= 3'b100;
        else stripe <= {stripe[0], stripe[2:1]};
    end

    reg [2:0] full_strength = 3'b111;
    always @(posedge pclk) begin
        if (!resetn || !game_pixel) full_strength <= 3'b111;
        else case (mode)
            2'd1: full_strength <= stripe;
            2'd2: full_strength <= odd_row ? {stripe[0], stripe[2:1]} : stripe;
            default: full_strength <= 3'b111;
        endcase
    end
    // Decode the frame-latched word. Reserved value 3 bypasses each control.
    reg tone_enabled = 0;
    always @(posedge pclk)
        tone_enabled <= resetn && game_pixel &&
                        (gamma_mode == 1 || gamma_mode == 2);

    // Read the transfer function on the same edge as the RGB compositor.
    // OSD, load text, borders and master OFF retain the composite pixel.
    for (genvar ch=0; ch<3; ch=ch+1) begin : phosphor_channel
        wire [7:0] corrected;
        crt_tone_channel tone(
            .pclk(pclk), .gamma_mode(gamma_mode),
            .sample(game_rgb[8*ch +: 8]), .corrected(corrected));
        wire [7:0] sample = tone_enabled ? corrected : composed_rgb[8*ch +: 8];
        assign rgb_out[8*ch +: 8] = full_strength[ch] ? sample : (sample >> 1);
    end
endmodule

// Address = {gamma preset, input code}. Presets 0 and 3 use unity gamma.
module crt_tone_channel (
    input wire pclk,
    input wire [1:0] gamma_mode,
    input wire [7:0] sample,
    output reg [7:0] corrected
);
    reg [7:0] transfer [0:1023] /* synthesis syn_ramstyle="block_ram" */;
    initial $readmemh("crt_gamma.hex", transfer);
    always @(posedge pclk) corrected <= transfer[{gamma_mode, sample}];
endmodule
