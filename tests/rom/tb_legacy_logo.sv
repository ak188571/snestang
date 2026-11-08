module tb_legacy_logo(input clk,resetn,input [7:0] x,y,input [31:0] write_data,
    input write_enable,output [14:0] color);
    textdisp #(.SHOW_LOGO(1)) original(.clk(clk),.hclk(clk),.resetn(resetn),.x(x),.y(y),
        .reg_char_di(write_data),.reg_char_we({4{write_enable}}),
        .load_row(1'b0),.load_char(8'h20),.color(color));
endmodule
