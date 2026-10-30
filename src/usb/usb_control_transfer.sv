// EP0 control read + no-data control write, one directly attached LS device.
// Bytes are published only through a committed read window after the status stage.
// Caller owns port reset, address/configuration application, and frame scheduling.
module usb_control_transfer #(
 parameter integer BUFFER_SIZE=256,ERROR_LIMIT=3,NAK_LIMIT=8,DUP_LIMIT=3,
 parameter integer TRANSFER_LIMIT=6000000
)(
 input wire clk,resetn,abort_transfer,start,transaction_grant,
 output reg transaction_active=0,
 input wire [6:0] device_address,
 input wire [63:0] setup_request,
 output reg busy=0,done=0,ok=0,cancel_link=0,
 output reg [3:0] error=0,
 output reg [8:0] actual_length=0,
 input wire [7:0] read_address,output wire [7:0] read_value,
 output reg tx_start=0,output reg [95:0] tx_bytes=0,output reg [3:0] tx_count=0,
 input wire tx_done,output reg rx_arm=0,
 input wire rx_done,rx_ok,rx_timeout,
 input wire [7:0] rx_pid,input wire [3:0] rx_length,input wire [63:0] rx_data,
 output wire [3:0] debug_stage,output wire [8:0] debug_offset
);
 localparam IDLE=0,ISSUE=1,TX_WAIT=2,GAP=3,RX_WAIT=4,ACK_GAP=5,ACK_WAIT=6,FAIL=7,COPY_PAYLOAD=8;
 localparam SETUP_TOKEN=0,SETUP_DATA=1,READ_TOKEN=2,STATUS_OUT_TOKEN=3,
            STATUS_OUT_DATA=4,STATUS_IN_TOKEN=5;
 reg [3:0] state=IDLE,stage=0,after_gap=0;
 reg [6:0] address=0;
 reg [63:0] request=0;
 reg [15:0] requested=0;
 reg [8:0] offset=0;
 reg [7:0] memory[0:BUFFER_SIZE-1];
 reg expected_toggle=1,duplicate_packet=0,final_packet=0;
 reg [3:0] packet_size=0;
 reg [63:0] packet_data=0;
 reg [2:0] copy_index=0;
 reg [7:0] errors=0,naks=0,duplicates=0;
 reg [5:0] gap=0;
 reg [22:0] lifetime=0;
 assign debug_stage=stage;
 assign debug_offset=offset;
 // One synchronous read port, with one-cycle address-to-data latency.
 reg [7:0] memory_read=0;
 always @(posedge clk)begin
  if(!resetn || abort_transfer || !ok)memory_read<=0;
  else if({1'b0,read_address}<actual_length)memory_read<=memory[read_address];
  else memory_read<=0;
 end
 assign read_value=(ok && {1'b0,read_address}<actual_length) ? memory_read : 8'd0;
 function automatic [95:0] token(input [7:0] pid,input [6:0] adr);
  reg [10:0] bits11;reg [4:0] c;reg [15:0] payload;reg f;
  bits11={4'd0,adr};c=5'h1f;
  for(integer j=0;j<11;j=j+1)begin
   f=c[0]^bits11[j];c=c>>1;if(f)c=c^5'h14;
  end
  payload={~c,bits11};
  return {64'd0,payload,pid,8'h80};
 endfunction
 function automatic [95:0] data_packet(input [7:0] pid,input [63:0] payload,input bit empty);
  reg [15:0] c;reg f;
  c=16'hffff;
  if(!empty)for(integer j=0;j<64;j=j+1)begin
   f=c[0]^payload[j];c=c>>1;if(f)c=c^16'ha001;
  end
  if(empty)return {64'd0,~c,pid,8'h80};
  return {~c,payload,pid,8'h80};
 endfunction
 task automatic fail(input [3:0] why);
  error<=why;state<=FAIL;
 endtask
 task automatic retry_stage(input bit flow_control);
  if(flow_control)begin
   if(int'(naks)+1>=NAK_LIMIT)fail(4'd2);
   else begin naks<=naks+1'b1;gap<=24;after_gap<=stage;state<=GAP;end
  end else begin
   if(int'(errors)+1>=ERROR_LIMIT)fail(rx_timeout ? 4'd6 : 4'd1);
   else begin errors<=errors+1'b1;gap<=24;after_gap<=stage;state<=GAP;end
  end
 endtask
 integer i;
 always @(posedge clk)begin
  tx_start<=0;rx_arm<=0;done<=0;cancel_link<=0;
  if(!resetn || abort_transfer)begin
   transaction_active<=0;state<=IDLE;stage<=0;busy<=0;done<=0;ok<=0;error<=0;actual_length<=0;
   offset<=0;expected_toggle<=1;errors<=0;naks<=0;duplicates<=0;lifetime<=0;
   request<=0;address<=0;requested<=0;gap<=0;after_gap<=0;
   duplicate_packet<=0;final_packet<=0;packet_size<=0;packet_data<=0;
   tx_bytes<=0;tx_count<=0;copy_index<=0;
  end else begin
   if(busy)lifetime<=lifetime+1'b1;
   case(state)
    IDLE: if(start)begin
     busy<=1;ok<=0;error<=0;actual_length<=0;offset<=0;lifetime<=0;
     request<=setup_request;requested<=setup_request[63:48];address<=device_address;
     expected_toggle<=1;errors<=0;naks<=0;duplicates<=0;stage<=SETUP_TOKEN;
     if(int'(setup_request[63:48])>BUFFER_SIZE || (!setup_request[7] && setup_request[63:48]!=0))fail(4'd7);
     else state<=ISSUE;
    end
    ISSUE: if(stage==SETUP_DATA || stage==STATUS_OUT_DATA || transaction_grant)begin
     tx_start<=1;state<=TX_WAIT;
     if(stage!=SETUP_DATA && stage!=STATUS_OUT_DATA)transaction_active<=1;
     case(stage)
      SETUP_TOKEN:begin tx_bytes<=token(8'h2d,address);tx_count<=4;end
      SETUP_DATA:begin tx_bytes<=data_packet(8'hc3,request,0);tx_count<=12;end
      READ_TOKEN,STATUS_IN_TOKEN:begin tx_bytes<=token(8'h69,address);tx_count<=4;end
      STATUS_OUT_TOKEN:begin tx_bytes<=token(8'he1,address);tx_count<=4;end
      STATUS_OUT_DATA:begin tx_bytes<=data_packet(8'h4b,0,1);tx_count<=4;end
      default:begin tx_start<=0;fail(4'd7);end
     endcase
    end
    TX_WAIT:if(tx_done)begin
     if(stage==SETUP_TOKEN || stage==STATUS_OUT_TOKEN)begin
      after_gap<=stage==SETUP_TOKEN ? SETUP_DATA : STATUS_OUT_DATA;gap<=16;state<=GAP;
     end else begin rx_arm<=1;state<=RX_WAIT;end
    end
    GAP:if(gap!=0)gap<=gap-1'b1;
        else begin stage<=after_gap;state<=ISSUE;end
    RX_WAIT:if(rx_done)begin
     transaction_active<=0;
     if(!rx_ok)begin
      // SETUP retry must repeat the token as well as its DATA0 packet.
      if(stage==SETUP_DATA)stage<=SETUP_TOKEN;
      if(stage==STATUS_OUT_DATA)stage<=STATUS_OUT_TOKEN;
      retry_stage(0);
      if(stage==SETUP_DATA)after_gap<=SETUP_TOKEN;
      if(stage==STATUS_OUT_DATA)after_gap<=STATUS_OUT_TOKEN;
     end else if(rx_pid==8'h1e)fail(4'd3);
     else if(rx_pid==8'h5a && stage!=SETUP_DATA)begin
      retry_stage(1);
      if(stage==STATUS_OUT_DATA)after_gap<=STATUS_OUT_TOKEN;
     end else if((stage==SETUP_DATA || stage==STATUS_OUT_DATA) && rx_pid==8'hd2)begin
      errors<=0;naks<=0;duplicates<=0;
      if(stage==SETUP_DATA)begin
       stage<=requested==0 ? STATUS_IN_TOKEN : READ_TOKEN;state<=GAP;
       after_gap<=requested==0 ? STATUS_IN_TOKEN : READ_TOKEN;gap<=16;
      end else begin busy<=0;done<=1;ok<=1;actual_length<=offset;state<=IDLE;end
     end else if((stage==READ_TOKEN || stage==STATUS_IN_TOKEN) && (rx_pid==8'hc3 || rx_pid==8'h4b))begin
      if(stage==STATUS_IN_TOKEN && (rx_pid!=8'h4b || rx_length!=0))fail(4'd4);
      else if(stage==READ_TOKEN && rx_length>8)fail(4'd4);
      else if(stage==READ_TOKEN && (rx_pid==8'h4b)==expected_toggle &&
              ({7'd0,offset}+{12'd0,rx_length}>requested || int'(offset)+int'(rx_length)>BUFFER_SIZE))fail(4'd5);
      else begin
       transaction_active<=1;
       duplicate_packet<=stage==READ_TOKEN && ((rx_pid==8'h4b)!=expected_toggle);
       packet_data<=rx_data;packet_size<=rx_length;
       final_packet<=stage==STATUS_IN_TOKEN || rx_length<8;
       // A full 256-byte read also ends by length, without an extra IN.
       if(stage==READ_TOKEN && {7'd0,offset}+{12'd0,rx_length}==requested)final_packet<=1;
       gap<=16;state<=ACK_GAP;
      end
     end else begin
      if(stage==SETUP_DATA)stage<=SETUP_TOKEN;
      if(stage==STATUS_OUT_DATA)stage<=STATUS_OUT_TOKEN;
      retry_stage(0);
      if(stage==SETUP_DATA)after_gap<=SETUP_TOKEN;
      if(stage==STATUS_OUT_DATA)after_gap<=STATUS_OUT_TOKEN;
     end
    end
    ACK_GAP:if(gap!=0)gap<=gap-1'b1;
     else begin tx_bytes<=96'hd280;tx_count<=2;tx_start<=1;state<=ACK_WAIT;end
    ACK_WAIT:if(tx_done)begin
     transaction_active<=0;
     if(duplicate_packet)begin
      if(int'(duplicates)+1>=DUP_LIMIT)fail(4'd8);
      else begin duplicates<=duplicates+1'b1;after_gap<=READ_TOKEN;gap<=16;state<=GAP;end
     end else if(stage==STATUS_IN_TOKEN)begin
      busy<=0;done<=1;ok<=1;actual_length<=0;state<=IDLE;
     end else begin
      // ACK has finished. Copy one byte/clock so the buffer has one write port.
      copy_index<=0;state<=COPY_PAYLOAD;
     end
    end
    COPY_PAYLOAD:begin
     if(packet_size!=0)memory[offset[7:0]+{5'd0,copy_index}]<=packet_data[8*copy_index+:8];
     if(packet_size==0 || {1'b0,copy_index}+1'b1>=packet_size)begin
      offset<=offset+{5'd0,packet_size};expected_toggle<=~expected_toggle;
      errors<=0;naks<=0;duplicates<=0;
      after_gap<=final_packet ? STATUS_OUT_TOKEN : READ_TOKEN;gap<=16;state<=GAP;
     end else copy_index<=copy_index+1'b1;
    end
    FAIL:begin transaction_active<=0;busy<=0;done<=1;ok<=0;actual_length<=0;cancel_link<=1;state<=IDLE;end
    default:fail(4'd7);
   endcase
   if(busy && int'(lifetime)==TRANSFER_LIMIT-1 && state!=FAIL)fail(4'd9);
  end
 end
endmodule
