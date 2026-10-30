// Experimental LS direct port, integrated behind the preserved TangCore decoder.
// 12 MHz only. Default timing is real clock counts, not accelerated test values.
module usb_game_port #(
 parameter integer EXTERNAL_IO=0,
 parameter integer ATTACH_CLOCKS=1200000,RESET_CLOCKS=120000,RECOVERY_CLOCKS=120000
)(
 input wire usbclk,usbrst_n,
 inout wire usb_dp,usb_dm,
 // External IO mode keeps every internal connection unidirectional.
 input wire usb_dp_in,usb_dm_in,
 output wire usb_dp_out,usb_dm_out,
 output wire usb_oe,
 output reg ukprdy=0,ukpstb=0,output reg [7:0] ukpdat=0,
 output reg save=0,output reg [3:0] save_r=0,save_b=0,
 output wire connected,conerr,start_wait,
 output reg payload_valid=0,output reg [3:0] payload_length=0
);
 localparam WAIT_ATTACH=0,DEBOUNCE=1,BUS_RESET=2,RECOVERY=3,ENUMERATE=4,
            PUBLISH=5,ACTIVE=6,FAILED=7,UNSUPPORTED=8;
 reg [3:0] port_state=WAIT_ATTACH;
 reg [7:0] port_error=0;
 reg [20:0] timer=0;
 reg ls_candidate=0;
 reg dp_meta=0,dm_meta=0,dp_sync=0,dm_sync=0;
 wire ls_idle=!dp_sync && dm_sync;
 wire fs_idle=dp_sync && !dm_sync;
 wire se0=!dp_sync && !dm_sync;
 reg [5:0] disconnect_count=0;
 wire bus_reset=port_state==BUS_RESET;
 wire operating=port_state==ENUMERATE || port_state==PUBLISH || port_state==ACTIVE;
 wire recovering=port_state==RECOVERY;
 wire logic_resetn=usbrst_n && operating;
 wire phy_enabled=usbrst_n && (operating || recovering);
 assign connected=port_state==ACTIVE;
 assign conerr=!(port_state==PUBLISH || port_state==ACTIVE) || !usbrst_n;
 wire enum_busy,enum_ready,enum_fault;
 wire [7:0] enum_error;
 wire [6:0] address;
 wire [15:0] vid,pid,report_bytes;
 wire enum_report_id_valid;wire [7:0] enum_report_id;
 wire [7:0] configuration,interface_number,endpoint_address,interval_ms;
 reg enum_start=0;
 wire ctl_start,ctl_done,ctl_ok,ctl_cancel,ctl_active;
 wire [63:0] request;
 wire [3:0] ctl_error;
 wire [8:0] ctl_length;
 wire [7:0] read_address,read_value;
 wire ctl_tx_start,ctl_rx_arm;
 wire [95:0] ctl_tx_bytes;wire [3:0] ctl_tx_count;
 wire tx_busy,tx_done,rx_done,rx_ok,rx_timeout;
 wire [7:0] rx_pid;wire [3:0] rx_length;wire [63:0] rx_data;
 wire poll_busy,poll_done,poll_fault,poll_report,poll_tx_start,poll_rx_arm;
 wire [3:0] poll_error,poll_tx_count;
 wire [95:0] poll_tx_bytes;wire [63:0] poll_data;
 wire expected_toggle;
 reg poll_start=0;
 reg [7:0] poll_frames=0;
 reg first_poll=1,poll_due=0;
 wire frame_grant,ka_start,ka_active,frame_tick,schedule_fault;
 wire [13:0] frame_phase;
 wire transaction_active=ctl_active || poll_busy;
 usb_frame_scheduler frames(.clk(usbclk),.resetn(usbrst_n),.enable(operating || recovering),
  .transaction_active(transaction_active),.phy_busy(tx_busy),.phy_done(tx_done),
  .grant(frame_grant),.keepalive_start(ka_start),.keepalive_active(ka_active),
  .frame_tick(frame_tick),.fault(schedule_fault),.frame_phase(frame_phase));
 usb_enumeration enumeration(.clk(usbclk),.resetn(logic_resetn),.start(enum_start),.abort_enumeration(1'b0),
  .busy(enum_busy),.ready(enum_ready),.fault(enum_fault),.error(enum_error),.device_address(address),
  .vid(vid),.pid(pid),.configuration(configuration),.interface_number(interface_number),
  .endpoint_address(endpoint_address),.interval_ms(interval_ms),.report_bytes(report_bytes),
  .report_id_valid(enum_report_id_valid),.input_report_id(enum_report_id),
  .control_start(ctl_start),.control_request(request),.control_done(ctl_done),.control_ok(ctl_ok),
  .control_error(ctl_error),.control_length(ctl_length),.read_address(read_address),.read_value(read_value),.debug_phase());
 usb_control_transfer control(.clk(usbclk),.resetn(logic_resetn),.abort_transfer(1'b0),.start(ctl_start),
  .transaction_grant(frame_grant),.transaction_active(ctl_active),.device_address(address),.setup_request(request),
  .busy(),.done(ctl_done),.ok(ctl_ok),.cancel_link(ctl_cancel),.error(ctl_error),.actual_length(ctl_length),
  .read_address(read_address),.read_value(read_value),.tx_start(ctl_tx_start),.tx_bytes(ctl_tx_bytes),
  .tx_count(ctl_tx_count),.tx_done(tx_done),.rx_arm(ctl_rx_arm),.rx_done(rx_done),.rx_ok(rx_ok),
  .rx_timeout(rx_timeout),.rx_pid(rx_pid),.rx_length(rx_length),.rx_data(rx_data),.debug_stage(),.debug_offset());
 usb_interrupt_poll poll(.clk(usbclk),.resetn(usbrst_n && port_state==ACTIVE),.start(poll_start),
  .address(address),.endpoint(endpoint_address[3:0]),.check_report_id(enum_report_id_valid),
  .expected_report_id(enum_report_id),.busy(poll_busy),.done(poll_done),.fault(poll_fault),
  .error(poll_error),.report(poll_report),.report_data(poll_data),.expected_toggle(expected_toggle),
  .tx_start(poll_tx_start),.tx_bytes(poll_tx_bytes),.tx_count(poll_tx_count),.tx_done(tx_done),
  .rx_arm(poll_rx_arm),.rx_done(rx_done),.rx_ok(rx_ok),.rx_timeout(rx_timeout),
  .rx_pid(rx_pid),.rx_length(rx_length),.rx_data(rx_data));
 wire selected_tx_start=ka_start || ctl_tx_start || poll_tx_start;
 wire [95:0] selected_tx_bytes=ka_start ? 96'd0 : (port_state==ACTIVE ? poll_tx_bytes : ctl_tx_bytes);
 wire [3:0] selected_tx_count=ka_start ? 4'd0 : (port_state==ACTIVE ? poll_tx_count : ctl_tx_count);
 usb_ls_packet #(.EXTERNAL_IO(EXTERNAL_IO)) phy(.clk(usbclk),.resetn(phy_enabled && !ctl_cancel),.bus_reset(bus_reset),
  .usb_dp(usb_dp),.usb_dm(usb_dm),.usb_dp_in(usb_dp_in),.usb_dm_in(usb_dm_in),
  .usb_dp_out(usb_dp_out),.usb_dm_out(usb_dm_out),.tx_start(selected_tx_start),.tx_bytes(selected_tx_bytes),
  .tx_count(selected_tx_count),.tx_busy(tx_busy),.tx_done(tx_done),
  .rx_arm(ctl_rx_arm || poll_rx_arm),.rx_done(rx_done),.rx_ok(rx_ok),.rx_timeout(rx_timeout),
  .rx_pid(rx_pid),.rx_length(rx_length),.rx_data(rx_data),.output_enable(usb_oe));
 reg rx_waiting=0;
 assign start_wait=rx_waiting;
 reg [63:0] emit_data=0;
 reg [2:0] emit_index=0;
 reg emit_phase=0;
 reg [2:0] info_phase=0;
 reg [3:0] save_index=0;
 always @(posedge usbclk)begin
  enum_start<=0;poll_start<=0;save<=0;
  if(!usbrst_n)begin
   port_state<=WAIT_ATTACH;port_error<=0;timer<=0;ls_candidate<=0;disconnect_count<=0;
   dp_meta<=0;dm_meta<=0;dp_sync<=0;dm_sync<=0;
   ukprdy<=0;ukpstb<=0;ukpdat<=0;payload_valid<=0;payload_length<=0;
   emit_data<=0;emit_index<=0;emit_phase<=0;info_phase<=0;save_index<=0;save_r<=0;save_b<=0;
   poll_frames<=0;first_poll<=1;poll_due<=0;rx_waiting<=0;
  end else begin
   dp_meta<=EXTERNAL_IO!=0 ? usb_dp_in : usb_dp;
   dm_meta<=EXTERNAL_IO!=0 ? usb_dm_in : usb_dm;dp_sync<=dp_meta;dm_sync<=dm_meta;
   if(ctl_rx_arm || poll_rx_arm)rx_waiting<=1;else if(rx_done)rx_waiting<=0;
   if(!phy_enabled)rx_waiting<=0;
   if(ukprdy)begin
    if(!emit_phase)begin ukpdat<=emit_data[8*emit_index+:8];ukpstb<=1;emit_phase<=1;end
    else begin
     ukpstb<=0;emit_phase<=0;
     if({1'b0,emit_index}+1'b1>=payload_length)ukprdy<=0;
     else emit_index<=emit_index+1'b1;
    end
   end
   if(!operating)begin
    ukprdy<=0;ukpstb<=0;payload_valid<=0;payload_length<=0;poll_frames<=0;first_poll<=1;poll_due<=0;
   end
   if((operating || port_state==FAILED || port_state==UNSUPPORTED) && !usb_oe && se0)begin
    if(disconnect_count<32)disconnect_count<=disconnect_count+1'b1;
   end else disconnect_count<=0;
   case(port_state)
    WAIT_ATTACH:begin
     timer<=0;
     if(ls_idle || fs_idle)begin ls_candidate<=ls_idle;port_state<=DEBOUNCE;end
    end
    DEBOUNCE:if((ls_candidate && !ls_idle) || (!ls_candidate && !fs_idle))begin port_state<=WAIT_ATTACH;timer<=0;end
     else if(int'(timer)==ATTACH_CLOCKS-1)begin
      timer<=0;
      if(ls_candidate)port_state<=BUS_RESET;
      else begin port_state<=UNSUPPORTED;port_error<=8'h41;end
     end else timer<=timer+1'b1;
    BUS_RESET:if(int'(timer)==RESET_CLOCKS-1)begin timer<=0;port_state<=RECOVERY;end
              else timer<=timer+1'b1;
    RECOVERY:if(int'(timer)>=RECOVERY_CLOCKS-1)begin
      if(frame_grant && !tx_busy)begin port_state<=ENUMERATE;enum_start<=1;timer<=0;end
     end else timer<=timer+1'b1;
    ENUMERATE:if(enum_fault)begin port_state<=FAILED;port_error<=8'h80 | enum_error;end
     else if(enum_ready)begin
      if((vid==16'h0079 && pid==16'h0006) || (vid==16'h0810 && pid==16'h0001) ||
         (vid==16'h11ff && pid==16'h3331))begin
       port_state<=PUBLISH;info_phase<=0;timer<=0;save_index<=0;
      end else begin port_state<=UNSUPPORTED;port_error<=8'h42;end
     end
    PUBLISH:case(info_phase)
     0:begin
      emit_data<={8'd0,8'd0,8'd0,8'd3,pid[15:8],pid[7:0],vid[15:8],vid[7:0]};
      payload_length<=7;payload_valid<=1;emit_index<=0;emit_phase<=0;ukprdy<=1;info_phase<=1;
     end
     1:if(!ukprdy)begin info_phase<=2;timer<=0;end
     2:if(timer==3)info_phase<=3;else timer<=timer+1'b1;
     3:begin save<=1;save_r<=save_index;save_b<=save_index;info_phase<=4;end
     4:if(save_index==6)begin info_phase<=5;timer<=0;end
       else begin save_index<=save_index+1'b1;info_phase<=3;end
     5:if(timer==4)begin port_state<=ACTIVE;poll_frames<=0;first_poll<=1;poll_due<=0;end
       else timer<=timer+1'b1;
     default:begin port_state<=FAILED;port_error<=8'h43;end
    endcase
    ACTIVE:begin
     if(frame_tick)begin
      if(first_poll || int'(poll_frames)+1>=int'(interval_ms))poll_due<=1;
      else poll_frames<=poll_frames+1'b1;
     end
     if(poll_due && frame_grant && !poll_busy && !poll_start && !ukprdy)begin
      poll_start<=1;poll_frames<=0;first_poll<=0;poll_due<=0;
     end
     if(poll_report)begin
      emit_data<=poll_data;payload_length<=8;payload_valid<=1;emit_index<=0;emit_phase<=0;ukprdy<=1;
     end
     if(poll_fault)begin port_state<=FAILED;port_error<=8'h50 | {4'd0,poll_error};end
    end
    FAILED,UNSUPPORTED:begin end
    default:begin port_state<=FAILED;port_error<=8'hff;end
   endcase
   if(schedule_fault)begin port_state<=FAILED;port_error<=8'h60;end
   // A started packet that never releases the bus is not an idle/no-response
   // retry. Disable this port before any following frame keep-alive can drive it.
   if(rx_done && rx_timeout && !ls_idle)begin port_state<=FAILED;port_error<=8'h61;end
   if(disconnect_count==32)begin
    port_state<=WAIT_ATTACH;timer<=0;disconnect_count<=0;ukprdy<=0;ukpstb<=0;save<=0;payload_valid<=0;
   end
  end
 end
endmodule
