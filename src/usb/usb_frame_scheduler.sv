// LS root-port frame timing at 12 MHz. A transaction, including its response/ACK,
// is indivisible. Only its initial token needs a grant.
module usb_frame_scheduler #(
 parameter integer FRAME_CLOCKS=12000,TRANSACTION_BUDGET=2304
)(
 input wire clk,resetn,enable,transaction_active,phy_busy,phy_done,
 output wire grant,
 output reg keepalive_start=0,frame_tick=0,fault=0,
 output reg keepalive_active=0,
 output reg [13:0] frame_phase=0
);
 reg pending=1;
 reg [4:0] gap=16;
 assign grant=enable && !fault && !pending && !keepalive_active && gap==0 &&
              int'(frame_phase)<FRAME_CLOCKS-TRANSACTION_BUDGET;
 always @(posedge clk)begin
  keepalive_start<=0;frame_tick<=0;
  if(!resetn || !enable)begin
   pending<=1;gap<=16;fault<=0;keepalive_active<=0;frame_phase<=0;
  end else if(!fault)begin
   if(int'(frame_phase)<FRAME_CLOCKS+1)frame_phase<=frame_phase+1'b1;
   if(int'(frame_phase)==FRAME_CLOCKS-2)pending<=1;
   if(gap!=0)gap<=gap-1'b1;
   if(keepalive_active && phy_done)begin keepalive_active<=0;gap<=16;end
   if(pending && !transaction_active && !phy_busy && !keepalive_active && gap==0)begin
    keepalive_start<=1;frame_tick<=1;keepalive_active<=1;pending<=0;frame_phase<=0;
   end
   if(pending && int'(frame_phase)>=FRAME_CLOCKS && transaction_active)fault<=1;
  end
 end
endmodule
