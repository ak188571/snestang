// Two clocks, one physical direct root port. FS ownership suppresses the LS path.
// The complete FS game state and connection flag cross atomically to clk12.
module usb_dual_speed_host #(
 parameter integer POSITION_FACE=0
)(
 input wire usbclk,usbrst_n,usbclk96,usbrst96_n,
 inout wire usb_dp,usb_dm,
 output wire [11:0] game_snes,
 output wire [1:0] typ,
 output wire report,conerr,dbg_connected,
 output wire dbg_auto_start_seen,dbg_auto_wdt_seen,
 output wire dbg_fs_owner,
 output wire [3:0] dbg_fs_state,
 output wire [7:0] dbg_fs_error,
 output wire [7:0] dbg_fs_context,
 output wire [23:0] dbg_fs_first_unexpected,
 output wire [63:0] dbg_hid_report
);
 wire fs_owner,fs_connected,fs_report,fs_oe;
 assign dbg_fs_owner=fs_owner;
 assign dbg_fs_error=fs_error;
 wire ls_oe,fs_dp_out,fs_dm_out,ls_dp_out,ls_dm_out;
 // Each physical pad has one driver. Neither internal PHY drives a shared net.
 wire pad_oe=usbrst_n && usbrst96_n && (fs_owner ? fs_oe : ls_oe);
 assign usb_dp=pad_oe ? (fs_owner ? fs_dp_out : ls_dp_out) : 1'bz;
 assign usb_dm=pad_oe ? (fs_owner ? fs_dm_out : ls_dm_out) : 1'bz;
 wire [159:0] fs_data;wire[7:0] fs_error;wire[1:0] init_status;
 usb_xusb_port #(.EXTERNAL_IO(1)) fs(.clk(usbclk96),.resetn(usbrst96_n),.usb_dp(),.usb_dm(),
  .usb_dp_in(usb_dp),.usb_dm_in(usb_dm),.usb_dp_out(fs_dp_out),.usb_dm_out(fs_dm_out),
  .debug_state(dbg_fs_state),.debug_context(dbg_fs_context),.debug_first_unexpected(dbg_fs_first_unexpected),.usb_oe(fs_oe),.owner(fs_owner),.connected(fs_connected),.report(fs_report),.report_data(fs_data),
  .error(fs_error),.initialization_status(init_status));
 wire fields_valid;wire[15:0] buttons;wire[7:0] lt,rt;
 wire signed[15:0] lx,ly,rx,ry;
 usb_xusb_input decode(.clk(usbclk96),.resetn(usbrst96_n),.link_active(fs_connected),
  .packet_valid(fs_report),.packet_length(6'd20),.packet_data({96'd0,fs_data}),.report(fields_valid),
  .format_error(),.buttons(buttons),.left_trigger(lt),.right_trigger(rt),.left_x(lx),.left_y(ly),
  .right_x(rx),.right_y(ry),.uninterpreted_tail());
 wire [11:0] fs_game={buttons[9],buttons[8],
  POSITION_FACE!=0 ? buttons[15] : buttons[14],POSITION_FACE!=0 ? buttons[13] : buttons[12],
  (buttons[3] || lx>16'sd16000),(buttons[2] || lx< -16'sd16000),
  (buttons[1] || ly< -16'sd16000),(buttons[0] || ly>16'sd16000),buttons[4],buttons[5],
  POSITION_FACE!=0 ? buttons[14] : buttons[15],POSITION_FACE!=0 ? buttons[12] : buttons[13]};
 reg fs_sequence=0,fs_seen=0;
 always @(posedge usbclk96)if(!usbrst96_n || !fs_connected)fs_sequence<=0;else if(fields_valid)fs_sequence<=~fs_sequence;
 wire[13:0] fs_snapshot;wire fs_update;
 usb_game_cdc #(.WIDTH(14),.REFRESH_CLOCKS(96000)) fs_to_ls(
  .src_clk(usbclk96),.src_resetn(usbrst96_n),.src_valid(fields_valid),
  .src_data({fs_connected,fs_sequence,fs_game}),.dst_clk(usbclk),.dst_resetn(usbrst_n),
  .dst_data(fs_snapshot),.dst_valid(fs_update));
 reg[1:0] owner_sync=0;
 always @(posedge usbclk)if(!usbrst_n)owner_sync<=0;else owner_sync<={owner_sync[0],fs_owner};
 wire[11:0] ls_game;wire[1:0] ls_typ;
 wire ls_report,ls_error,ls_connected,ls_start,ls_wdt;wire[63:0] ls_debug;
 usb_hid_host #(.EXTERNAL_IO(1)) ls(.usbclk(usbclk),.usbrst_n(usbrst_n && !owner_sync[1]),.usb_dp(),.usb_dm(),
  .usb_dp_in(usb_dp),.usb_dm_in(usb_dm),.usb_dp_out(ls_dp_out),.usb_dm_out(ls_dm_out),.usb_output_enable(ls_oe),
  .game_snes(ls_game),.typ(ls_typ),.report(ls_report),.conerr(ls_error),.dbg_connected(ls_connected),
  .dbg_auto_start_seen(ls_start),.dbg_auto_wdt_seen(ls_wdt),.dbg_hid_report(ls_debug));
 wire fs_live=owner_sync[1] && fs_snapshot[13];
 always @(posedge usbclk)if(!usbrst_n || !fs_live)fs_seen<=0;else if(fs_update)fs_seen<=fs_snapshot[12];
 assign game_snes=!usbrst_n ? 12'd0 : owner_sync[1] ? (fs_live ? fs_snapshot[11:0] : 12'd0) : ls_game;
 assign typ=owner_sync[1] ? (fs_live ? 2'd3 : 2'd0) : ls_typ;
 assign dbg_connected=owner_sync[1] ? fs_live : ls_connected;
 assign conerr=owner_sync[1] ? !fs_live : ls_error;
 assign report=usbrst_n && (owner_sync[1] ? fs_update && fs_live && fs_snapshot[12]!=fs_seen : ls_report);
 assign dbg_auto_start_seen=owner_sync[1] ? 1'b0 : ls_start;
 assign dbg_auto_wdt_seen=owner_sync[1] ? 1'b0 : ls_wdt;
 assign dbg_hid_report=owner_sync[1] ? 64'd0 : ls_debug;
endmodule
