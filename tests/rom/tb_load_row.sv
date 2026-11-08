// Synchronous model of the dual-port OSD memory, using the synthesis font.
module gowin_dpb_menu(input clka, reseta, ocea, cea, wrea, input [10:0] ada,
    input [7:0] dina, output reg [7:0] douta,
    input clkb, resetb, oceb, ceb, wreb, input [10:0] adb, input [7:0] dinb, output reg [7:0] doutb);
    reg [7:0] memory[0:2047];
    initial $readmemh("build-rom-tests/label-font.hex",memory);
    always @(posedge clka) if(cea) begin
        douta<=memory[ada];
        if(wrea) memory[ada]<=dina;
    end
    always @(posedge clkb) if(ceb) doutb<=memory[adb];
endmodule

module tb_load_row(input clk,resetn,frame_start,input [4:0] status,
    input [7:0] x,y,input [31:0] write_data,input write_ref,write_actual,
    output wire [14:0] actual,expected_color,output wire load_row,output wire [7:0] load_char);
    tc_load_label label(.clk(clk),.resetn(resetn),.frame_start(frame_start),.status(status),
        .column(x[7:3]),.row(y[7:3]),.load_row(load_row),.load_char(load_char));
    textdisp #(.SHOW_LOGO(0),.LOAD_STATUS(1)) tested(.clk(clk),.hclk(clk),.resetn(resetn),.x(x),.y(y),
        .reg_char_di(write_data),.reg_char_we({4{write_actual}}),.load_row(load_row),.load_char(load_char),.color(actual));
    textdisp #(.SHOW_LOGO(0)) original(.clk(clk),.hclk(clk),.resetn(resetn),.x(x),.y(y),
        .reg_char_di(write_data),.reg_char_we({4{write_ref}}),.load_row(1'b0),.load_char(8'h20),.color(expected_color));
endmodule
