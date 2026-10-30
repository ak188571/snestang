// One selected Xbox 045e:028e interrupt IN endpoint at 96 MHz / Full-Speed.
// The caller owns address/endpoint validation, 1 ms SOF and bInterval scheduling.
// Caller grants a complete slot and enforces bInterval. CRC-valid short packets
// are ACKed/toggled at the USB layer but never published as partial input.
// Only exact 20-byte 00/14 input records publish. Nonzero record types
// are ACKed/toggled and ignored without consuming the malformed-input budget.
// Empty or malformed type00 records and duplicate/corrupt replies remain bounded.
module usb_xusb_poll(
 input wire clk,resetn,start,
 input wire [6:0] address,input wire [3:0] endpoint,
 output reg busy,done,fault,
 output reg [3:0] error,
 output reg report,output reg [159:0] report_data,
 output reg tx_start,output reg [95:0] tx_bytes,output reg [3:0] tx_count,
 input wire tx_done,output reg rx_arm,
 input wire rx_done,rx_ok,rx_timeout,input wire [7:0] rx_pid,
 input wire [5:0] rx_length,input wire [255:0] rx_data,
 output reg [23:0] debug_first_unexpected=0,
 output reg expected_toggle
);
 localparam IDLE=0,TX_WAIT=1,RX_WAIT=2,ACK_GAP=3,ACK_WAIT=4;
 reg [2:0] state=0;
 reg [4:0] gap=0;
 reg [1:0] errors=0,duplicates=0,shorts=0;
 reg publish=0,pending_fault=0;
 reg [159:0] staged=0;
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
   staged<=0;report_data<=0;tx_bytes<=0;tx_count<=0;debug_first_unexpected<=0;
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
     staged<=rx_data[159:0];gap<=16;state<=ACK_GAP;
     if((rx_pid==8'h4b)!=expected_toggle)begin
      if(duplicates==2)begin pending_fault<=1;error<=5;end
      else duplicates<=duplicates+1'b1;
     end else begin
      expected_toggle<=~expected_toggle;errors<=0;duplicates<=0;
      if(rx_length==20 && rx_data[15:0]==16'h1400)begin publish<=1;shorts<=0;end
      else begin
       // Sticky first unique unexpected record: valid, non-input type, length, byte0/1.
       if(!debug_first_unexpected[23])debug_first_unexpected<=
         {1'b1,(rx_length!=0 && rx_data[7:0]!=0),rx_length,rx_data[7:0],
          (rx_length>=2 ? rx_data[15:8] : 8'd0)};
       if(rx_length==0 || rx_data[7:0]==0)begin
        if(shorts==2)begin pending_fault<=1;error<=rx_length==20 ? 9 : 7;end
        else shorts<=shorts+1'b1;
       end
      end
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
