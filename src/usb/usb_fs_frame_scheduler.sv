// Full-Speed root-port SOF scheduler, 96 MHz; not a Low-Speed keep-alive.
// Caller supplies an indivisible transaction and must discard its link on fault.
module usb_fs_frame_scheduler #(
 parameter integer FRAME_CLOCKS=96000,TRANSACTION_BUDGET=4096
)(
 input wire clk,resetn,enable,transaction_active,phy_busy,phy_done,
 output wire grant,
 output reg sof_start,frame_tick,fault,sof_active,
 output reg [95:0] sof_bytes,
 output reg [10:0] frame_number,
 output reg [16:0] frame_phase
);
 reg pending=1;
 reg [4:0] gap=16;
 reg [10:0] next_number=0;
 assign grant=enable && !fault && !pending && !sof_active && gap==0 &&
              int'(frame_phase)<FRAME_CLOCKS-TRANSACTION_BUDGET;
 function automatic [95:0] sof(input [10:0] number);
  reg [4:0] crc;
  crc=5'h1f;
  for(integer i=0;i<11;i=i+1)crc=(crc[0]^number[i]) ? ((crc>>1)^5'h14) : (crc>>1);
  return {64'd0,~crc,number,8'ha5,8'h80};
 endfunction
 always @(posedge clk)begin
  sof_start<=0;frame_tick<=0;
  if(!resetn || !enable)begin
   pending<=1;gap<=16;fault<=0;sof_active<=0;frame_phase<=0;
   sof_bytes<=0;frame_number<=0;next_number<=0;
  end else if(!fault)begin
   if(int'(frame_phase)<FRAME_CLOCKS+1)frame_phase<=frame_phase+1'b1;
   if(int'(frame_phase)==FRAME_CLOCKS-2)pending<=1;
   if(gap!=0)gap<=gap-1'b1;
   if(sof_active && phy_done)begin sof_active<=0;gap<=16;end
   if(pending && !transaction_active && !phy_busy && !sof_active && gap==0)begin
    sof_start<=1;frame_tick<=1;sof_active<=1;pending<=0;frame_phase<=0;
    sof_bytes<=sof(next_number);frame_number<=next_number;next_number<=next_number+1'b1;
   end
   if(pending && int'(frame_phase)>=FRAME_CLOCKS)fault<=1;
  end
 end
endmodule
