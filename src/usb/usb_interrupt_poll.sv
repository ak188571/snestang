// One selected interrupt IN endpoint, one directly attached LS device.
// Caller grants a complete slot and enforces bInterval. CRC-valid short packets
// are ACKed/toggled at the USB layer but never published as partial input.
// A CRC-valid wrong Report ID is also ACKed/toggled, ignored, and bounded.
module usb_interrupt_poll(
 input wire clk,resetn,start,
 input wire [6:0] address,input wire [3:0] endpoint,
 input wire check_report_id,input wire [7:0] expected_report_id,
 output reg busy=0,done=0,fault=0,
 output reg [3:0] error=0,
 output reg report=0,output reg [63:0] report_data=0,
 output reg tx_start=0,output reg [95:0] tx_bytes=0,output reg [3:0] tx_count=0,
 input wire tx_done,output reg rx_arm=0,
 input wire rx_done,rx_ok,rx_timeout,input wire [7:0] rx_pid,
 input wire [3:0] rx_length,input wire [63:0] rx_data,
 output reg expected_toggle=0
);
 localparam IDLE=0,TX_WAIT=1,RX_WAIT=2,ACK_GAP=3,ACK_WAIT=4;
 reg [2:0] state=0;
 reg [4:0] gap=0;
 reg [1:0] errors=0,duplicates=0,shorts=0;
 reg publish=0,pending_fault=0;
 reg [63:0] staged=0;
 function automatic [95:0] in_token(input [6:0] adr,input [3:0] ep);
  reg [10:0] bits11;reg [4:0] c;reg f;
  bits11={ep,adr};c=5'h1f;
  for(integer j=0;j<11;j=j+1)begin f=c[0]^bits11[j];c=c>>1;if(f)c=c^5'h14;end
  return {64'd0,~c,bits11,8'h69,8'h80};
 endfunction
 always @(posedge clk)begin
  done<=0;report<=0;tx_start<=0;rx_arm<=0;
  if(!resetn)begin
   busy<=0;fault<=0;error<=0;expected_toggle<=0;state<=IDLE;gap<=0;
   errors<=0;duplicates<=0;shorts<=0;publish<=0;pending_fault<=0;
   staged<=0;report_data<=0;tx_bytes<=0;tx_count<=0;
  end else if(!fault)case(state)
   IDLE:if(start)begin
    busy<=1;tx_start<=1;tx_bytes<=in_token(address,endpoint);tx_count<=4;
    publish<=0;pending_fault<=0;state<=TX_WAIT;
   end
   TX_WAIT:if(tx_done)begin rx_arm<=1;state<=RX_WAIT;end
   RX_WAIT:if(rx_done)begin
    if(!rx_ok || (rx_pid!=8'hc3 && rx_pid!=8'h4b && rx_pid!=8'h5a && rx_pid!=8'h1e))begin
     busy<=0;done<=1;state<=IDLE;
     if(errors==2)begin fault<=1;error<=rx_timeout ? 6 : 1;end
     else errors<=errors+1'b1;
    end else if(rx_pid==8'h1e)begin busy<=0;done<=1;fault<=1;error<=3;state<=IDLE;end
    else if(rx_pid==8'h5a)begin busy<=0;done<=1;errors<=0;state<=IDLE;end
    else begin
     staged<=rx_data;gap<=16;state<=ACK_GAP;
     if((rx_pid==8'h4b)!=expected_toggle)begin
      if(duplicates==2)begin pending_fault<=1;error<=5;end
      else duplicates<=duplicates+1'b1;
     end else begin
      expected_toggle<=~expected_toggle;errors<=0;duplicates<=0;
      if(rx_length==8 && (!check_report_id || rx_data[7:0]==expected_report_id))begin publish<=1;shorts<=0;end
      else if(shorts==2)begin pending_fault<=1;error<=rx_length==8 ? 9 : 7;end
      else shorts<=shorts+1'b1;
     end
    end
   end
   ACK_GAP:if(gap!=0)gap<=gap-1'b1;
    else begin tx_start<=1;tx_bytes<=96'hd280;tx_count<=2;state<=ACK_WAIT;end
   ACK_WAIT:if(tx_done)begin
    busy<=0;done<=1;state<=IDLE;
    if(publish)begin report<=1;report_data<=staged;end
    if(pending_fault)fault<=1;
   end
   default:begin fault<=1;error<=8;busy<=0;end
  endcase
 end
endmodule
