// Front-end for the existing yellow 8x8 OSD font. No writes to OSD RAM.
module tc_load_label(
    input wire clk, resetn, frame_start,
    input wire [4:0] status, column, row,
    output wire load_row,
    output reg [7:0] load_char
);
    reg [4:0] visible=0;
    always @(posedge clk) begin
        if (!resetn) visible <= 0;
        else if (frame_start) begin
            // END can arrive before the last DATA status was scanned out.
            if (status==23 && visible>=2 && visible<22) visible <= 22;
            else visible <= status;
        end
    end

    assign load_row = visible!=0 && row==27;
    localparam [19*8-1:0] PREPARE="Preparing SNES core";
    localparam [13*8-1:0] TRANSFER="ROM transfer ";
    localparam [13*8-1:0] VERIFY="Verifying ROM";

    reg [31:0] percentage;
    always @* begin
        case (visible)
            5'd2: percentage="0%  ";
            5'd3: percentage="5%  ";
            5'd4: percentage="10% ";
            5'd5: percentage="15% ";
            5'd6: percentage="20% ";
            5'd7: percentage="25% ";
            5'd8: percentage="30% ";
            5'd9: percentage="35% ";
            5'd10: percentage="40% ";
            5'd11: percentage="45% ";
            5'd12: percentage="50% ";
            5'd13: percentage="55% ";
            5'd14: percentage="60% ";
            5'd15: percentage="65% ";
            5'd16: percentage="70% ";
            5'd17: percentage="75% ";
            5'd18: percentage="80% ";
            5'd19: percentage="85% ";
            5'd20: percentage="90% ";
            5'd21: percentage="95% ";
            5'd22: percentage="100%";
            default: percentage="    ";
        endcase
        load_char = " ";
        if (column!=0) begin
            if (visible==1 && column<=19)
                load_char = PREPARE[(19-column)*8+:8];
            else if (visible==23 && column<=13)
                load_char = VERIFY[(13-column)*8+:8];
            else if (visible>=2 && visible<=22) begin
                if (column<=13) load_char = TRANSFER[(13-column)*8+:8];
                else if (column<=17) load_char = percentage[(17-column)*8+:8];
            end
        end
    end
endmodule
