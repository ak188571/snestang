// Observed 045e:028e wired-controller 00/14 record, committed atomically.
// Raw fields only: game-button mapping is deliberately owned by a later adapter.
// USB CRC/PID/toggle checks are the responsibility of the upstream packet/poll.
module usb_xusb_input(
 input wire clk,resetn,link_active,packet_valid,
 input wire [5:0] packet_length,
 input wire [255:0] packet_data,
 output reg report,format_error,
 output reg [15:0] buttons,
 output reg [7:0] left_trigger,right_trigger,
 output reg signed [15:0] left_x,left_y,right_x,right_y,
 output reg [47:0] uninterpreted_tail
);
 always @(posedge clk)begin
  report<=0;format_error<=0;
  if(!resetn || !link_active)begin
   buttons<=0;left_trigger<=0;right_trigger<=0;
   left_x<=0;left_y<=0;right_x<=0;right_y<=0;uninterpreted_tail<=0;
  end else if(packet_valid)begin
   if(packet_length!=20 || packet_data[15:0]!=16'h1400)format_error<=1;
   else begin
    buttons<=packet_data[31:16];
    left_trigger<=packet_data[39:32];right_trigger<=packet_data[47:40];
    left_x<=packet_data[63:48];left_y<=packet_data[79:64];
    right_x<=packet_data[95:80];right_y<=packet_data[111:96];
    uninterpreted_tail<=packet_data[159:112];report<=1;
   end
  end
 end
endmodule
