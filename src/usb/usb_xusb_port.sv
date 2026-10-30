// Direct Full-Speed root port at 96 MHz. Only the observed 045e:028e profile.
module usb_xusb_port #(
 parameter integer EXTERNAL_IO=0,
 parameter integer ATTACH_CLOCKS=9600000,RESET_CLOCKS=960000,RECOVERY_CLOCKS=960000
)(
 input wire clk,resetn,
 inout wire usb_dp,usb_dm,
 // External IO mode keeps every internal connection unidirectional.
 input wire usb_dp_in,usb_dm_in,
 output wire usb_dp_out,usb_dm_out,
 output wire [3:0] debug_state,
 output reg [7:0] debug_context=0,
 output reg [23:0] debug_first_unexpected=0,
 output wire usb_oe,connected,
 output reg owner,
 output wire report,output wire [159:0] report_data,
 output reg [7:0] error,
 output wire [1:0] initialization_status
);
 localparam WAIT_ATTACH=0,DEBOUNCE=1,BUS_RESET=2,RECOVERY=3,ENUMERATE=4,ACTIVE=6,FAILED=7;
 reg[3:0] state=0;
 assign debug_state=state;
 reg[24:0] timer=0;
 reg dp_meta=0,dm_meta=0,dp_sync=0,dm_sync=0;
 reg[7:0] disconnect_count=0;
 wire idle=dp_sync && !dm_sync,se0=!dp_sync && !dm_sync;
 wire bus_reset=state==BUS_RESET;
 wire operating=state==ENUMERATE || state==ACTIVE;
 wire phy_enabled=resetn && (operating || state==RECOVERY);
 wire [2:0] enum_phase;wire [3:0] ctl_stage;
 wire enum_ready,enum_fault;wire[7:0] enum_error,endpoint,interval;
 wire[6:0] address;
 reg enum_start=0;
 wire ctl_start,ctl_done,ctl_ok,ctl_cancel,ctl_active;
 wire[63:0] request;wire[3:0] ctl_error;wire[8:0] ctl_length;
 wire[7:0] read_address,read_value;
 wire ctl_tx_start,ctl_rx_arm;wire[95:0] ctl_bytes;wire[3:0] ctl_count;
 wire tx_busy,tx_done,rx_done,rx_ok,rx_timeout;wire[7:0] rx_pid;
 wire[5:0] rx_length;wire[255:0] rx_data;
 wire [23:0] poll_first_unexpected;
 wire poll_busy,poll_done,poll_fault,poll_report,poll_tx_start,poll_arm;
 wire[3:0] poll_error,poll_count;wire[95:0] poll_bytes;wire[159:0] poll_data;
 reg poll_start=0,poll_due=0,first_poll=1;reg[7:0] poll_frames=0;
 wire grant,sof_start,sof_active,frame_tick,schedule_fault;
 wire[95:0] sof_bytes;
 assign connected=state==ACTIVE;
 assign report=connected && poll_report;
 assign report_data=connected ? poll_data : 160'd0;
 usb_fs_frame_scheduler frames(.clk(clk),.resetn(resetn),.enable(operating || state==RECOVERY),
  .transaction_active(ctl_active || poll_busy),.phy_busy(tx_busy),.phy_done(tx_done),.grant(grant),
  .sof_start(sof_start),.sof_bytes(sof_bytes),.sof_active(sof_active),.frame_tick(frame_tick),
  .fault(schedule_fault),.frame_number(),.frame_phase());
 usb_xusb_enumeration enumeration(.clk(clk),.resetn(resetn && operating),.start(enum_start),
  .busy(),.ready(enum_ready),.fault(enum_fault),.error(enum_error),.device_address(address),
  .endpoint_address(endpoint),.interval_ms(interval),.initialization_status(initialization_status),.debug_phase(enum_phase),
  .control_start(ctl_start),.control_request(request),.control_done(ctl_done),.control_ok(ctl_ok),
  .control_error(ctl_error),.control_length(ctl_length),.read_address(read_address),.read_value(read_value));
 usb_fs_control_transfer control(.clk(clk),.resetn(resetn && operating),.abort_transfer(1'b0),.start(ctl_start),
  .transaction_grant(grant),.transaction_active(ctl_active),.device_address(address),.setup_request(request),
  .busy(),.done(ctl_done),.ok(ctl_ok),.cancel_link(ctl_cancel),.error(ctl_error),.actual_length(ctl_length),
  .read_address(read_address),.read_value(read_value),.tx_start(ctl_tx_start),.tx_bytes(ctl_bytes),
  .tx_count(ctl_count),.tx_done(tx_done),.rx_arm(ctl_rx_arm),.rx_done(rx_done),.rx_ok(rx_ok),
  .rx_timeout(rx_timeout),.rx_pid(rx_pid),.rx_length(rx_length),.rx_data(rx_data[63:0]),.debug_stage(ctl_stage),.debug_offset());
 usb_xusb_poll poll(.clk(clk),.resetn(resetn && connected),.start(poll_start),.address(address),
  .endpoint(endpoint[3:0]),.busy(poll_busy),.done(poll_done),.fault(poll_fault),.error(poll_error),
  .report(poll_report),.report_data(poll_data),.debug_first_unexpected(poll_first_unexpected),.expected_toggle(),.tx_start(poll_tx_start),
  .tx_bytes(poll_bytes),.tx_count(poll_count),.tx_done(tx_done),.rx_arm(poll_arm),
  .rx_done(rx_done),.rx_ok(rx_ok),.rx_timeout(rx_timeout),.rx_pid(rx_pid),.rx_length(rx_length),.rx_data(rx_data));
 usb_fs_packet #(.EXTERNAL_IO(EXTERNAL_IO)) phy(.clk(clk),.resetn(phy_enabled && !ctl_cancel),.bus_reset(bus_reset),
  .usb_dp(usb_dp),.usb_dm(usb_dm),.usb_dp_in(usb_dp_in),.usb_dm_in(usb_dm_in),
  .usb_dp_out(usb_dp_out),.usb_dm_out(usb_dm_out),.tx_start(sof_start || ctl_tx_start || poll_tx_start),
  .tx_bytes({192'd0,sof_start ? sof_bytes : (connected ? poll_bytes : ctl_bytes)}),
  .tx_count(sof_start ? 6'd4 : {2'd0,connected ? poll_count : ctl_count}),
  .tx_busy(tx_busy),.tx_done(tx_done),.tx_rejected(),.rx_arm(ctl_rx_arm || poll_arm),
  .rx_done(rx_done),.rx_ok(rx_ok),.rx_timeout(rx_timeout),.rx_pid(rx_pid),.rx_length(rx_length),.rx_data(rx_data),.output_enable(usb_oe));
 always @(posedge clk)begin
  enum_start<=0;poll_start<=0;
  if(!resetn)begin
   state<=WAIT_ATTACH;owner<=0;timer<=0;error<=0;debug_context<=0;debug_first_unexpected<=0;
   dp_meta<=0;dm_meta<=0;dp_sync<=0;dm_sync<=0;disconnect_count<=0;
   poll_frames<=0;poll_due<=0;first_poll<=1;
  end else begin
   // Retain the last request/stage when a fault disables enumeration.
   // Bit7=fault or skipped optional probe; bit6=enumeration complete.
   if(operating)debug_first_unexpected<=poll_first_unexpected;
   if(operating)debug_context<={enum_fault || poll_fault || schedule_fault ||
      (rx_done && rx_timeout && !idle) || initialization_status==2,
      enum_ready,enum_phase,ctl_stage[2:0]};
   dp_meta<=EXTERNAL_IO!=0 ? usb_dp_in : usb_dp;
   dm_meta<=EXTERNAL_IO!=0 ? usb_dm_in : usb_dm;dp_sync<=dp_meta;dm_sync<=dm_meta;
   if(owner && !bus_reset && !usb_oe && se0)begin
    if(disconnect_count<240)disconnect_count<=disconnect_count+1'b1;
   end else disconnect_count<=0;
   case(state)
    WAIT_ATTACH:begin timer<=0;if(idle)state<=DEBOUNCE;end
    DEBOUNCE:if(!idle)begin state<=WAIT_ATTACH;timer<=0;end
     else if(int'(timer)==ATTACH_CLOCKS-1)begin state<=BUS_RESET;timer<=0;owner<=1;error<=0;end
     else timer<=timer+1'b1;
    BUS_RESET:if(int'(timer)==RESET_CLOCKS-1)begin state<=RECOVERY;timer<=0;end
     else timer<=timer+1'b1;
    RECOVERY:if(int'(timer)>=RECOVERY_CLOCKS-1)begin
      if(grant && !tx_busy)begin state<=ENUMERATE;enum_start<=1;timer<=0;end
     end else timer<=timer+1'b1;
    ENUMERATE:if(enum_fault)begin state<=FAILED;error<=enum_error;end
     else if(enum_ready)begin state<=ACTIVE;poll_frames<=0;first_poll<=1;poll_due<=0;end
    ACTIVE:begin
     if(frame_tick)begin
      if(first_poll || int'(poll_frames)+1>=int'(interval))poll_due<=1;
      else poll_frames<=poll_frames+1'b1;
     end
     if(poll_due && grant && !poll_busy && !poll_start)begin
      poll_start<=1;poll_due<=0;poll_frames<=0;first_poll<=0;
     end
     if(poll_fault)begin state<=FAILED;error<=8'h50|{4'd0,poll_error};end
    end
    FAILED:begin end
    default:begin state<=FAILED;error<=8'hff;end
   endcase
   if(schedule_fault)begin state<=FAILED;error<=8'h60;end
   if(rx_done && rx_timeout && !idle)begin state<=FAILED;error<=8'h61;end
   if(disconnect_count==240)begin state<=WAIT_ATTACH;owner<=0;timer<=0;disconnect_count<=0;end
  end
 end
endmodule
