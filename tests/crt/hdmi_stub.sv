// Tests the real RGB/scaler/OSD paths; replaces only HDMI serialization/vendor I/O.
module hdmi #(
    parameter VIDEO_ID_CODE=4,DVI_OUTPUT=0,VIDEO_REFRESH_RATE=60.0,IT_CONTENT=1,
    AUDIO_RATE=48000,AUDIO_BIT_WIDTH=16,START_X=0,START_Y=0
)(input wire clk_pixel_x5,clk_pixel,clk_audio,reset,
   input wire [23:0] rgb,input wire [15:0] audio_sample_word[1:0],
   output wire [2:0] tmds,output wire tmds_clock,
   output reg [10:0] cx=0,output reg [9:0] cy=0,
   output wire [10:0] frame_width,output wire [9:0] frame_height);
    assign frame_width=1280;assign frame_height=720;
    assign tmds=rgb[2:0];assign tmds_clock=clk_pixel;
    always @(posedge clk_pixel)begin
        if(cx==1649)begin cx<=0;cy<=cy==749?0:cy+1'b1;end else cx<=cx+1'b1;
    end
endmodule
module ELVDS_OBUF(input wire I,output wire O,OB);
    assign O=I;assign OB=~I;
endmodule
