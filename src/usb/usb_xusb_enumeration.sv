// Bounded enumeration for the observed wired 045e:028e, EP0 max packet 8.
// No HID requests: select FF/5D/01 interface from the returned configuration.
module usb_xusb_enumeration #(
 parameter integer ADDRESS_SETTLE_CYCLES=192000,VENDOR_PROBE=1
)(
 input wire clk,resetn,start,
 output reg busy,ready,fault,
 output reg [7:0] error,
 output reg [6:0] device_address,
 output wire [7:0] endpoint_address,interval_ms,
 output reg [1:0] initialization_status,
 output reg control_start,output reg [63:0] control_request,
 input wire control_done,control_ok,input wire [3:0] control_error,
 input wire [8:0] control_length,
 output wire [7:0] read_address,input wire [7:0] read_value,
 output wire [2:0] debug_phase
);
 localparam IDLE=0,ISSUE=1,WAIT_CTL=2,COPY_WAIT=3,COPY=4,VALIDATE=5,SETTLE=6,PARSE=7,FINISH=8,STOP=9,HEADER_WAIT=10,HEADER_LOAD=11,PARSE_EXEC=12,PARSE_CHECK=13;
 localparam DEV8=0,ADDRESS=1,DEV18=2,CFG9=3,CFGALL=4,CONFIGURE=5,VENDOR=6;
 reg [3:0] state=IDLE,phase=0;
 assign debug_phase=phase[2:0];
 reg [7:0] memory[0:255];
 reg [7:0] header[0:8];
 reg [3:0] header_index=0;
 // Register descriptor checks before committing any parser state changes.
 // The cursor is at most 511 and bLength at most 255: ten bits are sufficient.
 wire [9:0] next_cursor={1'b0,cursor}+{2'b00,size};
 reg [9:0] parsed_next=0;
 reg base_valid=0,kind_invalid=0,interface_valid=0,interface_primary=0;
 reg interface_primary_valid=0,endpoint_valid=0,endpoint_primary_valid=0;
 reg [7:0] memory_byte=0;
 always @(posedge clk)memory_byte<=memory[cursor[7:0]+{4'd0,header_index}];
 reg [8:0] count=0,index=0,cursor=0;
 reg [17:0] settle=0;
 reg [15:0] total=0;
 reg [7:0] config_id=0,ep=0,interval=0;
 reg [3:0] interfaces=0;
 reg [2:0] expected_eps=0,seen_eps=0;
 reg current_interface=0,current_primary=0,primary_found=0,in_found=0,out_found=0;
 reg [31:0] endpoints=0;
 wire [7:0] size=header[0],kind=header[1];
 assign read_address=index[7:0];
 assign endpoint_address=ready ? ep : 0;
 assign interval_ms=ready ? interval : 0;
 function automatic [63:0] req(input [7:0] bm,r,input [15:0] v,i,n);
  return {n,i,v,r,bm};
 endfunction
 task automatic fail(input [7:0] why);fault<=1;error<=why;ready<=0;busy<=0;state<=STOP;endtask
 always @(posedge clk)begin
  control_start<=0;
  if(!resetn)begin
   state<=IDLE;phase<=0;busy<=0;ready<=0;fault<=0;error<=0;device_address<=0;
   initialization_status<=0;control_request<=0;count<=0;index<=0;cursor<=0;settle<=0;total<=0;
   parsed_next<=0;base_valid<=0;kind_invalid<=0;interface_valid<=0;interface_primary<=0;
   interface_primary_valid<=0;endpoint_valid<=0;endpoint_primary_valid<=0;
   header_index<=0;config_id<=0;ep<=0;interval<=0;interfaces<=0;expected_eps<=0;seen_eps<=0;
   current_interface<=0;current_primary<=0;primary_found<=0;in_found<=0;out_found<=0;endpoints<=0;
  end else case(state)
   IDLE:if(start)begin busy<=1;phase<=DEV8;state<=ISSUE;end
   ISSUE:begin
    control_start<=1;state<=WAIT_CTL;
    case(phase)
     DEV8:control_request<=req(8'h80,6,16'h0100,0,8);
     ADDRESS:control_request<=req(0,5,1,0,0);
     DEV18:control_request<=req(8'h80,6,16'h0100,0,18);
     CFG9:control_request<=req(8'h80,6,16'h0200,0,9);
     CFGALL:control_request<=req(8'h80,6,16'h0200,0,total);
     CONFIGURE:control_request<=req(0,9,{8'd0,config_id},0,0);
     VENDOR:control_request<=req(8'hc1,1,16'h0100,0,20);
     default:begin control_start<=0;fail(8'h01);end
    endcase
   end
   WAIT_CTL:if(control_done)begin
    // Only this optional vendor probe may fall through after bounded
    // readiness/idle timeout or STALL. Mandatory requests and corrupt replies
    // remain fatal. The probe lifetime matches the referenced xpad 25 ms call.
    if(!control_ok && phase==VENDOR &&
       (control_error==2 || control_error==3 || control_error==6 || control_error==9))begin
     initialization_status<=2;ready<=1;busy<=0;state<=STOP;
    end else if(!control_ok)fail(8'h20+{4'd0,control_error});
    else begin count<=control_length;index<=0;state<=control_length==0 ? VALIDATE : COPY_WAIT;end
   end
   COPY_WAIT:state<=COPY;
   COPY:begin
    memory[index[7:0]]<=read_value;
    if(index+1==count)state<=VALIDATE;
    else begin index<=index+1'b1;state<=COPY_WAIT;end
   end
   VALIDATE:case(phase)
    DEV8:if(count!=8 || memory[0]!=18 || memory[1]!=1 || memory[7]!=8)fail(8'h0a);
     else begin phase<=ADDRESS;state<=ISSUE;end
    ADDRESS:begin device_address<=1;settle<=0;state<=SETTLE;end
    DEV18:if(count!=18 || memory[0]!=18 || memory[1]!=1 || memory[7]!=8 || memory[17]!=1 ||
       {memory[9],memory[8]}!=16'h045e || {memory[11],memory[10]}!=16'h028e)fail(8'h0b);
     else begin phase<=CFG9;state<=ISSUE;end
    CFG9:if(count!=9 || memory[0]!=9 || memory[1]!=2 || memory[4]!=4 || memory[5]==0 ||
       {memory[3],memory[2]}<9 || {memory[3],memory[2]}>256)fail(8'h0c);
     else begin total<={memory[3],memory[2]};config_id<=memory[5];phase<=CFGALL;state<=ISSUE;end
    CFGALL:if({7'd0,count}!=total || memory[0]!=9 || memory[1]!=2 || memory[4]!=4 || memory[5]!=config_id ||
       {memory[3],memory[2]}!=total)fail(8'h0c);
     else begin cursor<=0;state<=PARSE;end
    CONFIGURE:if(VENDOR_PROBE!=0)begin phase<=VENDOR;state<=ISSUE;end
     else begin initialization_status<=3;ready<=1;busy<=0;state<=STOP;end
    VENDOR:begin initialization_status<=1;ready<=1;busy<=0;state<=STOP;end
    default:fail(8'h01);
   endcase
   SETTLE:if(int'(settle)==ADDRESS_SETTLE_CYCLES-1)begin phase<=DEV18;state<=ISSUE;end
    else settle<=settle+1'b1;
   PARSE:if({1'b0,cursor}+10'd2>{1'b0,count})fail(8'h0d);
    else begin header_index<=0;state<=HEADER_WAIT;end
   HEADER_WAIT:state<=HEADER_LOAD;
   HEADER_LOAD:begin
    // Always load the nine-byte cache. Fields beyond bLength are never used:
    // descriptor-specific minimum sizes and overall bounds are checked below.
    header[header_index]<=memory_byte;
    if(header_index==8)state<=PARSE_CHECK;
    else begin header_index<=header_index+1'b1;state<=HEADER_WAIT;end
   end
   PARSE_CHECK:begin
    parsed_next<=next_cursor;
    base_valid<=({1'b0,cursor}+10'd2<={1'b0,count}) && size>=2 && next_cursor<={1'b0,count};
    kind_invalid<=(kind==2 && cursor!=0) || kind==1;
    interface_valid<=size>=9 && header[2]<=3 && header[3]==0 && header[4]<=4 &&
      !interfaces[header[2][1:0]] && (!current_interface || seen_eps==expected_eps);
    interface_primary<=header[5]==8'hff && header[6]==8'h5d && header[7]==1;
    interface_primary_valid<=!primary_found && header[2]==0 && header[4]==2;
    endpoint_valid<=size>=7 && current_interface && seen_eps<expected_eps && header[2][3:0]!=0 &&
      header[2][6:4]==0 && !endpoints[{header[2][7],header[2][3:0]}] && header[3]==3 &&
      header[5]==0 && header[4]!=0 && header[4]<=32 && header[6]!=0;
    endpoint_primary_valid<=header[4]==32 && (header[2][7] ? !in_found : !out_found);
    state<=PARSE_EXEC;
   end
   PARSE_EXEC:begin
    if(!base_valid)fail(8'h0d);
    else begin
     cursor<=parsed_next[8:0];
     if(parsed_next=={1'b0,count})state<=FINISH;else state<=PARSE;
     if(kind_invalid)fail(8'h0d);
     if(kind==4)begin
      if(!interface_valid)fail(8'h0e);
      else begin
       interfaces[header[2][1:0]]<=1;current_interface<=1;
       expected_eps<=3'(header[4]);seen_eps<=0;
       current_primary<=interface_primary;
       if(interface_primary)begin
        if(!interface_primary_valid)fail(8'h0e);
        else primary_found<=1;
       end
      end
     end else if(kind==5)begin
      if(!endpoint_valid)fail(8'h0f);
      else begin
       endpoints[{header[2][7],header[2][3:0]}]<=1;seen_eps<=seen_eps+1'b1;
       if(current_primary)begin
        if(!endpoint_primary_valid)fail(8'h0f);
        else if(header[2][7])begin
         if(in_found)fail(8'h0f);
         else begin in_found<=1;ep<=header[2];interval<=header[6];end
        end else if(out_found)fail(8'h0f);else out_found<=1;
       end
      end
     end
    end
   end
   FINISH:if(interfaces!=4'b1111 || !primary_found || !in_found || !out_found || seen_eps!=expected_eps)fail(8'h10);
    else begin phase<=CONFIGURE;state<=ISSUE;end
   STOP:begin end
   default:fail(8'h01);
  endcase
 end
endmodule
