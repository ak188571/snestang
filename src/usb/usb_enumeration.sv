// Experimental LS/HID subset, invoked only after the caller's bus reset/recovery.
// No ROM addresses. Enumeration data is exposed only after every required status stage.
module usb_enumeration #(parameter integer ADDRESS_SETTLE_CYCLES=24000)(
 input wire clk,resetn,start,abort_enumeration,
 output reg busy=0,ready=0,fault=0,
 output reg [7:0] error=0,
 output reg [6:0] device_address=0,
 output wire [15:0] vid,pid,
 output wire [7:0] configuration,interface_number,endpoint_address,interval_ms,
 output wire [15:0] report_bytes,
 output wire report_id_valid,output wire [7:0] input_report_id,
 output reg control_start=0,output reg [63:0] control_request=0,
 input wire control_done,control_ok,input wire [3:0] control_error,
 input wire [8:0] control_length,
 output wire [7:0] read_address,input wire [7:0] read_value,
 output wire [3:0] debug_phase
);
 localparam IDLE=0,ISSUE=1,WAIT_CONTROL=2,COPY=3,VALIDATE=4,ADDRESS_WAIT=5,
            PARSE_CONFIG=6,CONFIG_DONE=7,PARSE_REPORT=8,REPORT_DONE=9,STOP=10,COPY_WAIT=11;
 localparam DEV8=0,SET_ADDRESS=1,DEV18=2,CONFIG9=3,CONFIG_ALL=4,SET_CONFIG=5,REPORT=6;
 reg [3:0] state=IDLE,phase=DEV8;
 reg [7:0] snapshot[0:255];
 reg [8:0] copy_index=0,count=0,cursor=0;
 reg [15:0] total=0,report_length=0,vid_cache=0,pid_cache=0;
 reg [7:0] config_cache=0,interface_cache=0,endpoint_cache=0,interval_cache=0;
 reg interface_match=0,hid_found=0,endpoint_found=0,interface_found=0;
 reg [15:0] settle=0;
 reg [7:0] report_id_cache=0;reg report_id_seen=0;
 reg [1:0] expected_endpoints=0,endpoint_records=0;reg out_found=0;
 reg [31:0] usage_page=0,usage=0,report_size=0,report_count=0,input_bits=0;
 reg [5:0] depth=0;
 reg gamepad_application=0;
 assign debug_phase=phase;
 assign read_address=copy_index[7:0];
 assign vid=ready ? vid_cache : 0;
 assign pid=ready ? pid_cache : 0;
 assign configuration=ready ? config_cache : 0;
 assign interface_number=ready ? interface_cache : 0;
 assign endpoint_address=ready ? endpoint_cache : 0;
 assign interval_ms=ready ? interval_cache : 0;
 assign report_bytes=ready ? 16'd8 : 0;
 assign report_id_valid=ready && report_id_seen;
 assign input_report_id=ready ? report_id_cache : 0;
 function automatic [63:0] request(input [7:0] bm,input [7:0] req,
    input [15:0] value,input [15:0] index,input [15:0] length);
  return {length,index,value,req,bm};
 endfunction
 task automatic fail(input [7:0] reason);
  fault<=1;error<=reason;ready<=0;busy<=0;state<=STOP;
 endtask
 wire [7:0] descriptor_length=snapshot[cursor[7:0]];
 wire [7:0] descriptor_type=snapshot[cursor[7:0]+8'd1];
 wire [7:0] item=snapshot[cursor[7:0]];
 wire [2:0] item_size=item[1:0]==3 ? 3'd4 : {1'b0,item[1:0]};
 reg [31:0] item_value;
 always @*begin
  item_value=0;
  for(integer j=0;j<4;j=j+1)
   if(j<int'(item_size) && int'(cursor)+j+1<int'(count))
    item_value[8*j+:8]=snapshot[int'(cursor)+j+1];
 end
 always @(posedge clk)begin
  control_start<=0;
  if(!resetn || abort_enumeration)begin
   state<=IDLE;phase<=DEV8;busy<=0;ready<=0;fault<=0;error<=0;device_address<=0;
   control_request<=0;copy_index<=0;count<=0;cursor<=0;total<=0;report_length<=0;
   vid_cache<=0;pid_cache<=0;config_cache<=0;interface_cache<=0;endpoint_cache<=0;interval_cache<=0;
   interface_match<=0;hid_found<=0;endpoint_found<=0;interface_found<=0;settle<=0;
   usage_page<=0;usage<=0;report_size<=0;report_count<=0;input_bits<=0;depth<=0;gamepad_application<=0;
   report_id_cache<=0;report_id_seen<=0;expected_endpoints<=0;endpoint_records<=0;out_found<=0;
  end else begin case(state)
   IDLE:if(start)begin busy<=1;ready<=0;phase<=DEV8;state<=ISSUE;end
   ISSUE:begin
    control_start<=1;state<=WAIT_CONTROL;
    case(phase)
     DEV8:control_request<=request(8'h80,6,16'h0100,0,8);
     SET_ADDRESS:control_request<=request(0,5,1,0,0);
     DEV18:control_request<=request(8'h80,6,16'h0100,0,18);
     CONFIG9:control_request<=request(8'h80,6,16'h0200,0,9);
     CONFIG_ALL:control_request<=request(8'h80,6,16'h0200,0,total);
     SET_CONFIG:control_request<=request(0,9,{8'd0,config_cache},0,0);
     REPORT:control_request<=request(8'h81,6,16'h2200,{8'd0,interface_cache},report_length);
     default:begin control_start<=0;fail(8'd10);end
    endcase
   end
   WAIT_CONTROL:if(control_done)begin
    if(!control_ok)fail(8'd32+{4'd0,control_error});
    else begin
     count<=control_length;copy_index<=0;
     state<=control_length==0 ? VALIDATE : COPY_WAIT;
    end
   end
   COPY_WAIT:state<=COPY; // synchronous buffer read latency
   COPY:begin
    snapshot[copy_index[7:0]]<=read_value;
    if(copy_index+1'b1==count)state<=VALIDATE;
    else begin copy_index<=copy_index+1'b1;state<=COPY_WAIT;end
   end
   VALIDATE:case(phase)
    DEV8:if(count!=8 || snapshot[0]!=18 || snapshot[1]!=1 || snapshot[7]!=8)fail(8'd10);
     else begin phase<=SET_ADDRESS;state<=ISSUE;end
    SET_ADDRESS:begin device_address<=1;settle<=0;state<=ADDRESS_WAIT;end
    DEV18:if(count!=18 || snapshot[0]!=18 || snapshot[1]!=1 || snapshot[7]!=8 || snapshot[17]==0)fail(8'd10);
     else begin
      vid_cache<={snapshot[9],snapshot[8]};pid_cache<={snapshot[11],snapshot[10]};
      phase<=CONFIG9;state<=ISSUE;
     end
    CONFIG9:if(count!=9 || snapshot[0]!=9 || snapshot[1]!=2 || snapshot[4]!=1 || snapshot[5]==0 ||
               {snapshot[3],snapshot[2]}<9 || {snapshot[3],snapshot[2]}>256)fail(8'd10);
     else begin
      total<={snapshot[3],snapshot[2]};config_cache<=snapshot[5];phase<=CONFIG_ALL;state<=ISSUE;
     end
    CONFIG_ALL:if({7'd0,count}!=total || snapshot[0]!=9 || snapshot[1]!=2 ||
                 {snapshot[3],snapshot[2]}!=total || snapshot[4]!=1 || snapshot[5]!=config_cache)fail(8'd10);
     else begin
      cursor<=0;interface_match<=0;hid_found<=0;endpoint_found<=0;interface_found<=0;
      expected_endpoints<=0;endpoint_records<=0;out_found<=0;state<=PARSE_CONFIG;
     end
    SET_CONFIG:begin phase<=REPORT;state<=ISSUE;end
    REPORT:if({7'd0,count}!=report_length)fail(8'd12);
     else begin
      cursor<=0;usage_page<=0;usage<=0;report_size<=0;report_count<=0;input_bits<=0;
      depth<=0;gamepad_application<=0;report_id_seen<=0;report_id_cache<=0;state<=PARSE_REPORT;
     end
    default:fail(8'd10);
   endcase
   ADDRESS_WAIT:if(int'(settle)==ADDRESS_SETTLE_CYCLES-1)begin phase<=DEV18;state<=ISSUE;end
                else settle<=settle+1'b1;
   PARSE_CONFIG:begin
    if(cursor+9'd2>count || descriptor_length<2 || int'(cursor)+int'(descriptor_length)>int'(count))fail(8'd10);
    else begin
     if((descriptor_type==2 && cursor!=0) || descriptor_type==1)fail(8'd10);
     if(descriptor_type==4)begin
      if(descriptor_length<9 || interface_found || snapshot[int'(cursor)+3]!=0 || (snapshot[int'(cursor)+4]!=1 && snapshot[int'(cursor)+4]!=2))fail(8'd11);
      else begin
       interface_found<=1;expected_endpoints<=2'(snapshot[int'(cursor)+4]);
       interface_match<=snapshot[int'(cursor)+5]==3 && snapshot[int'(cursor)+6]==0 && snapshot[int'(cursor)+7]==0;
       interface_cache<=snapshot[int'(cursor)+2];
      end
     end else if(descriptor_type==8'h21 && interface_match)begin
      if(descriptor_length<9 || hid_found || snapshot[int'(cursor)+5]!=1 || snapshot[int'(cursor)+6]!=8'h22 ||
         {snapshot[int'(cursor)+8],snapshot[int'(cursor)+7]}==0 ||
         {snapshot[int'(cursor)+8],snapshot[int'(cursor)+7]}>256)fail(8'd11);
      else begin hid_found<=1;report_length<={snapshot[int'(cursor)+8],snapshot[int'(cursor)+7]};end
     end else if(descriptor_type==5 && interface_match)begin
      // One selected interrupt IN and, optionally, one unused interrupt OUT.
      // IN/OUT may use the same endpoint number. Never transmit reports on OUT.
      if(descriptor_length<7 || !hid_found || endpoint_records>=expected_endpoints ||
         snapshot[int'(cursor)+2][3:0]==0 || snapshot[int'(cursor)+2][6:4]!=0 ||
         snapshot[int'(cursor)+3]!=3 || snapshot[int'(cursor)+6]<10 ||
         {snapshot[int'(cursor)+5],snapshot[int'(cursor)+4]}==0 ||
         {snapshot[int'(cursor)+5],snapshot[int'(cursor)+4]}>8)fail(8'd11);
      else if(snapshot[int'(cursor)+2][7])begin
       if(endpoint_found || {snapshot[int'(cursor)+5],snapshot[int'(cursor)+4]}!=8)fail(8'd11);
       else begin endpoint_found<=1;endpoint_cache<=snapshot[int'(cursor)+2];interval_cache<=snapshot[int'(cursor)+6];end
      end else begin
       if(out_found)fail(8'd11);else out_found<=1;
      end
      endpoint_records<=endpoint_records+1'b1;
     end
     cursor<=cursor+{1'b0,descriptor_length};
     if(int'(cursor)+int'(descriptor_length)==int'(count))state<=CONFIG_DONE;
    end
   end
   CONFIG_DONE:if(!interface_match || !hid_found || !endpoint_found || endpoint_records!=expected_endpoints ||
                  (expected_endpoints==2 && !out_found))fail(8'd11);
    else begin phase<=SET_CONFIG;state<=ISSUE;end
   PARSE_REPORT:begin
    if(item==8'hfe || item[3:2]==3 || (item & 8'hfc)==8'ha4 ||
       (item & 8'hfc)==8'hb4 || (item & 8'hfc)==8'ha8 ||
       ((item & 8'hfc)==8'ha0 && item!=8'ha1) || ((item & 8'hfc)==8'hc0 && item!=8'hc0) ||
       int'(cursor)+1+int'(item_size)>int'(count))fail(8'd12);
    else begin
     // The captured 0810 profile has a single Report ID 1 and seven
     // following data bytes. Reject mixed/unidentified/multiple-ID layouts.
     if((item & 8'hfc)==8'h84)begin
      if(item!=8'h85 || item_value!=1 || report_id_seen || input_bits!=0 ||
         vid_cache!=16'h0810 || pid_cache!=16'h0001)fail(8'd12);
      else begin report_id_seen<=1;report_id_cache<=8'd1;end
     end
     if((item & 8'hfc)==8'h04)usage_page<=item_value;
     if((item & 8'hfc)==8'h08)usage<=item_value;
     if((item & 8'hfc)==8'h74)report_size<=item_value;
     if((item & 8'hfc)==8'h94)report_count<=item_value;
     if(item==8'ha1)begin
      if(depth==0)begin
       if(gamepad_application || usage_page!=1 || (usage!=4 && usage!=5) || item_value!=1)fail(8'd12);
       else gamepad_application<=1;
      end
      if(depth==63)fail(8'd12);else depth<=depth+1'b1;
     end
     if(item==8'hc0)begin if(depth==0)fail(8'd12);else depth<=depth-1'b1;end
     if((item & 8'hfc)==8'h80)begin
      if(item!=8'h81 || depth==0 || report_size==0 || report_size>64 || report_count==0 || report_count>64 ||
         report_size*report_count>64 || input_bits+report_size*report_count>64)fail(8'd12);
      else input_bits<=input_bits+report_size*report_count;
     end
     if(item[3:2]==0)usage<=0;
     cursor<=cursor+1'b1+{6'd0,item_size};
     if(int'(cursor)+1+int'(item_size)==int'(count))state<=REPORT_DONE;
    end
   end
   REPORT_DONE:if(!gamepad_application || depth!=0 ||
      (report_id_seen ? input_bits!=56 : input_bits!=64) ||
      ((vid_cache==16'h0810 && pid_cache==16'h0001) && !report_id_seen))fail(8'd12);
    else begin ready<=1;busy<=0;state<=STOP;end
   STOP:begin end
   default:fail(8'd10);
  endcase
  if(fault)begin state<=STOP;control_start<=0;ready<=0;busy<=0;end
  end
 end
endmodule
