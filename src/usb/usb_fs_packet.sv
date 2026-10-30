// Experimental 96 MHz / 8x Full-Speed PHY, up to 32-byte payloads.
// Board clock/pin/electrical integration remains outstanding.
// tx_bytes includes SYNC/PID/CRC; the transmitter inserts stuffed bits and EOP.
module usb_fs_packet #(parameter integer EXTERNAL_IO=0)(
 input wire clk,resetn,bus_reset,
 inout wire usb_dm,usb_dp,
 // External IO mode keeps every internal connection unidirectional.
 input wire usb_dp_in,usb_dm_in,
 output wire usb_dp_out,usb_dm_out,
 input wire tx_start,input wire [287:0] tx_bytes,input wire [5:0] tx_count,
 output reg tx_busy,tx_done,tx_rejected,
 input wire rx_arm,
 output wire rx_done,rx_ok,rx_timeout,
 output wire [7:0] rx_pid,output wire [5:0] rx_length,
 output wire [255:0] rx_data,
 output wire output_enable
);
 reg dp_out=1,dm_out=0;
 reg [287:0] sending=0;
 reg [8:0] remaining=0,bit_index=0;
 reg [2:0] tick=0,ones=0;
 reg [1:0] tx_state=0;
 reg [4:0] end_count=0;
 assign output_enable=bus_reset || tx_busy;
 assign usb_dp_out=bus_reset ? 1'b0 : dp_out;
 wire line_dp=EXTERNAL_IO!=0 ? usb_dp_in : usb_dp;
 generate if(EXTERNAL_IO==0)begin:pad_dp
  assign usb_dp=output_enable ? usb_dp_out : 1'bz;
 end endgenerate
 assign usb_dm_out=bus_reset ? 1'b0 : dm_out;
 wire line_dm=EXTERNAL_IO!=0 ? usb_dm_in : usb_dm;
 generate if(EXTERNAL_IO==0)begin:pad_dm
  assign usb_dm=output_enable ? usb_dm_out : 1'bz;
 end endgenerate
 wire data_bit=sending[bit_index];
 always @(posedge clk)begin
  tx_done<=0;tx_rejected<=0;
  if(!resetn || bus_reset)begin
   tx_busy<=0;dp_out<=1;dm_out<=0;tick<=0;ones<=0;tx_state<=0;
   bit_index<=0;remaining<=0;sending<=0;end_count<=0;
  end else if(tx_start && !tx_busy && (tx_count<2 || tx_count>36))begin
   tx_rejected<=1;
  end else if(tx_start && !tx_busy)begin
   tx_busy<=1;sending<=tx_bytes;remaining<={tx_count,3'b000};bit_index<=0;
   tick<=0;ones<=0;tx_state<=0;dp_out<=1;dm_out<=0;
  end else if(tx_busy)begin
   if(tx_state==0)begin
    tick<=tick+1'b1;
    if(tick==0)begin
     if(ones==6)begin dp_out<=~dp_out;dm_out<=dp_out;ones<=0;end
     else if(remaining!=0)begin
      if(!data_bit)begin dp_out<=~dp_out;dm_out<=dp_out;end
      ones<=data_bit ? ones+3'd1 : 3'd0;
      remaining<=remaining-1'b1;bit_index<=bit_index+1'b1;
     end else begin
      // The previous data or stuffed bit has occupied all eight clocks.
      dp_out<=0;dm_out<=0;tx_state<=1;end_count<=1;
     end
    end
   end else if(tx_state==1)begin
    if(end_count==16)begin dp_out<=1;dm_out<=0;tx_state<=2;end_count<=1;end
    else end_count<=end_count+1'b1;
   end else begin
    if(end_count==8)begin tx_busy<=0;tx_done<=1;end
    else end_count<=end_count+1'b1;
   end
  end
 end
 reg dp_meta=1,dm_meta=0 /* synthesis syn_preserve=1 */;
 reg dm_sync=0,dp_sync=1,dm_prev=0,dp_prev=1,rx_active=0;
 reg [2:0] phase=0;
 reg [1:0] edge_hold=0;
 always @(posedge clk)begin
  if(!resetn || bus_reset)begin
   dp_meta<=1;dm_meta<=0;dm_sync<=0;dp_sync<=1;dm_prev<=0;dp_prev<=1;rx_active<=0;phase<=0;edge_hold<=0;
  end else begin
   dp_meta<=line_dp;dm_meta<=line_dm;dp_sync<=dp_meta;dm_sync<=dm_meta;
   dm_prev<=dm_sync;dp_prev<=dp_sync;
   if(rx_arm)begin rx_active<=1;phase<=0;edge_hold<=0;end
   else begin
    if(rx_done)rx_active<=0;
    if(rx_active)begin
     // The two single-ended pins can switch at different times. Align on the
     // first pin edge, then ignore its companion for three sample clocks.
     if(edge_hold!=0)edge_hold<=edge_hold-1'b1;
     if(edge_hold==0 && (dp_sync!=dp_prev || dm_sync!=dm_prev))begin
      phase<=1;edge_hold<=3;
     end else phase<=phase+1'b1;
    end
   end
  end
 end
 wire unused_ready,unused_strobe,unused_accepted;
 wire [7:0] unused_value;
 usb_fs_rx_guard guard(.clk(clk),.resetn(resetn && !bus_reset),.arm(rx_arm),
  .sample(rx_active && phase==4),.dm(dm_sync),.dp(dp_sync),.publish_data(1'b0),
  .done(rx_done),.ok(rx_ok),.timed_out(rx_timeout),.packet_pid(rx_pid),
  .length(rx_length),.ready(unused_ready),.strobe(unused_strobe),
  .value(unused_value),.accepted(unused_accepted),.payload(rx_data));
endmodule
