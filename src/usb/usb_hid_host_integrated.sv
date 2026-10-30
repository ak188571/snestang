// Experimental captured LS profiles; Windows-derived input fixtures, real USB report descriptors still required.
// Usb_hid_host: A compact USB HID host core.
//
// nand2mario, 8/2023, based on work by hi631
//
// This should support keyboard, mouse and gamepad input out of the box, over low-speed
// USB (1.5Mbps). Just connect D+, D-, VBUS (5V) and GND, and two 15K resistors between
// D+ and GND, D- and GND. Then provide a 12Mhz clock through usbclk.
//
// See https://github.com/nand2mario/usb_hid_host
//
// 3/22/2025: add LB and RB buttons, and SNES layout output `game_snes`

module usb_hid_host #(parameter integer EXTERNAL_IO=0) (
    input  usbclk,		            // 12MHz clock
    input  usbrst_n,	            // reset
    input wire usb_dp_in,usb_dm_in,
    output wire usb_dp_out,usb_dm_out,
    output wire usb_output_enable,
    inout  usb_dm, usb_dp,          // USB D- and D+

    output reg [1:0] typ,           // device type. 0: no device, 1: keyboard, 2: mouse, 3: gamepad
    output reg report,              // pulse after report received from device.
                                    // key_*, mouse_*, game_* valid depending on typ
    output conerr,                  // connection or protocol error

    // keyboard
    output reg [7:0] key_modifiers,
    output reg [7:0] key1, key2, key3, key4,

    // mouse
    output reg [7:0] mouse_btn,     // {5'bx, middle, right, left}
    output reg signed [7:0] mouse_dx,      // signed 8-bit, cleared after `report` pulse
    output reg signed [7:0] mouse_dy,      // signed 8-bit, cleared after `report` pulse

    // gamepad
    output [11:0] game_snes,        // SNES layout buttons (R L X A RT LT DN UP START SELECT Y B)
    output reg game_l, game_r, game_u, game_d,  // left right up down
    output reg game_a, game_b, game_x, game_y, game_sel, game_sta,  // buttons
    output reg game_lb, game_rb,

    // debug
    output [63:0] dbg_hid_report, // last HID report
    output dbg_connected,
    output reg dbg_auto_start_seen = 0,
    output reg dbg_auto_wdt_seen = 0
);

wire data_rdy;          // data ready
wire data_strobe;       // data strobe for each byte
wire [7:0] ukpdat;		// actual data
reg [7:0] regs [7];     // 0 (VID_L), 1 (VID_H), 2 (PID_L), 3 (PID_H), 4 (INTERFACE_CLASS), 5 (INTERFACE_SUBCLASS), 6 (INTERFACE_PROTOCOL)

// --- for controller vid:pid = 0810:0001 --- start
wire [15:0] dev_vid;
wire [15:0] dev_pid;
wire is_0810_0001;
wire is_elecom_11ff_3331;

assign dev_vid = {regs[1], regs[0]};
assign dev_pid = {regs[3], regs[2]};

assign is_0810_0001 =
    (dev_vid == 16'h0810) &&
    (dev_pid == 16'h0001);
assign is_elecom_11ff_3331 = (dev_vid==16'h11ff && dev_pid==16'h3331);
// --- for controller vid:pid = 0810:0001 --- end

wire packet_valid;
wire [3:0] packet_length;
wire save;			    // save dat[b] to output register r
wire [3:0] save_r;      // which register to save to
wire [3:0] save_b;      // dat[b]
wire connected;
wire unplugged=connected_r && !connected;
reg retry;              // retry because we did not detect a HID device
wire start_wait;
wire host_reset_n;
reg [20:0] start_wait_count = 0;
reg [15:0] reset_hold = 16'd60000;
reg recovery_armed = 0;
reg recovery_attempted = 0;
integer data_i;
integer regs_i;

// After a report, reset the entire host on a stalled START or UKP watchdog.
// A new report rearms recovery; no report means no reset loop.
assign host_reset_n = usbrst_n && reset_hold == 0;
assign dbg_connected = connected;
wire recovery_start_trigger = host_reset_n && recovery_armed && !recovery_attempted &&
                              start_wait && start_wait_count == 21'd1199999;
wire recovery_wdt_trigger = host_reset_n && recovery_armed && !recovery_attempted && conerr;
wire recovery_trigger = recovery_start_trigger || recovery_wdt_trigger;
always @(posedge usbclk) begin
    if (!usbrst_n) begin
        start_wait_count <= 0;
        reset_hold <= 16'd60000;
        recovery_armed <= 0;
        recovery_attempted <= 0;
        dbg_auto_start_seen <= 0;
        dbg_auto_wdt_seen <= 0;
    end else begin
        if (report) begin
            recovery_armed <= 1;
            recovery_attempted <= 0;
        end
        if (!host_reset_n || !start_wait || !recovery_armed || recovery_attempted)
            start_wait_count <= 0;
        else if (start_wait_count < 21'd1200000)
            start_wait_count <= start_wait_count + 1'b1;
        if (recovery_trigger) begin
            start_wait_count <= 0;
            reset_hold <= 16'd60000;
            recovery_attempted <= 1;
            if (recovery_start_trigger) dbg_auto_start_seen <= 1;
            if (recovery_wdt_trigger) dbg_auto_wdt_seen <= 1;
        end else if (reset_hold != 0)
            reset_hold <= reset_hold - 1'b1;
    end
end

assign game_snes = {game_rb, game_lb, game_x, game_a, game_r, game_l, game_d, game_u, game_sta, game_sel, game_y, game_b};

usb_game_port #(.EXTERNAL_IO(EXTERNAL_IO)) ukp(
    .usbrst_n(host_reset_n & ~retry), .usbclk(usbclk),
    .usb_dp(usb_dp), .usb_dm(usb_dm), .usb_oe(usb_output_enable),
    .usb_dp_in(usb_dp_in),.usb_dm_in(usb_dm_in),
    .usb_dp_out(usb_dp_out),.usb_dm_out(usb_dm_out),
    .ukprdy(data_rdy), .ukpstb(data_strobe), .ukpdat(ukpdat), .save(save), .save_r(save_r), .save_b(save_b),
    .connected(connected), .conerr(conerr), .start_wait(start_wait),
    .payload_valid(packet_valid), .payload_length(packet_length));

reg  [3:0] rcvct;		// counter for recv data
reg  data_strobe_r, data_rdy_r;	// delayed data_strobe and data_rdy
reg  [7:0] dat[8];		// data in last response
assign dbg_hid_report = {dat[7], dat[6], dat[5], dat[4], dat[3], dat[2], dat[1], dat[0]};
// assign dbg_regs = regs;

// Gamepad types, see response_recognition below
// localparam D_GENERIC = 0;
// localparam D_GAMEPAD = 1;
// localparam D_DS2_ADAPTER = 2;
// reg [3:0] dev = D_GENERIC;			// device type recognized through VID/PID
// assign dbg_dev = dev;

reg valid = 0;		    // whether current gamepad report is valid

reg pending_game_l = 0;
reg pending_game_r = 0;
reg pending_game_u = 0;
reg pending_game_d = 0;
reg pending_game_a = 0;
reg pending_game_b = 0;
reg pending_game_x = 0;
reg pending_game_y = 0;
reg pending_game_sel = 0;
reg pending_game_sta = 0;
reg pending_game_lb = 0;
reg pending_game_rb = 0;
always @(posedge usbclk) begin : process_in_data
    if (!host_reset_n || conerr || unplugged) begin
        data_rdy_r <= 0;
        data_strobe_r <= 0;
        rcvct <= 0;
        report <= 0;
        valid <= 0;
        key_modifiers <= 0;
        key1 <= 0; key2 <= 0; key3 <= 0; key4 <= 0;
        mouse_btn <= 0; mouse_dx <= 0; mouse_dy <= 0;
        pending_game_l <= 0; pending_game_r <= 0; pending_game_u <= 0; pending_game_d <= 0;
        pending_game_a <= 0; pending_game_b <= 0; pending_game_x <= 0; pending_game_y <= 0;
        pending_game_sel <= 0; pending_game_sta <= 0; pending_game_lb <= 0; pending_game_rb <= 0;
        for (data_i = 0; data_i < 8; data_i = data_i + 1)
            dat[data_i] <= 0;
    end else begin
    data_rdy_r <= data_rdy; data_strobe_r <= data_strobe;
    report <= 0;                    // ensure pulse
    if (report == 1) begin
        // clear mouse movement for later
        mouse_dx <= 0; mouse_dy <= 0;
    end
    if(~data_rdy) rcvct <= 0;
    else begin
        if(data_strobe && ~data_strobe_r) begin  // rising edge of ukp data strobe
            dat[rcvct] <= ukpdat;

            if (typ == 1) begin     // keyboard
                case (rcvct)
                0: key_modifiers <= ukpdat;
                2: key1 <= ukpdat;
                3: key2 <= ukpdat;
                4: key3 <= ukpdat;
                5: key4 <= ukpdat;
                endcase
            end else if (typ == 2) begin    // mouse
                case (rcvct)
                0: mouse_btn <= ukpdat;
                1: mouse_dx <= ukpdat;
                2: mouse_dy <= ukpdat;
                endcase
            end else if (typ == 3) begin    // gamepad
                if (is_elecom_11ff_3331) begin
                    // Observed green: D-pad/left stick share axes 0/1.
                    // Observed red: D-pad is hat 0..7, left stick stays axes 0/1.
                    // Combine hat and left stick; keep the existing 12-button
                    // game interface. Red right-stick axes remain unused.
                    case (rcvct)
                    5: begin
                        pending_game_l <= dat[0]<8'h40 || (ukpdat[3:0]>=5 && ukpdat[3:0]<=7);
                        pending_game_r <= dat[0]>8'hc0 || (ukpdat[3:0]>=1 && ukpdat[3:0]<=3);
                        pending_game_u <= dat[1]<8'h40 || (ukpdat[3:0]==0 || ukpdat[3:0]==1 || ukpdat[3:0]==7);
                        pending_game_d <= dat[1]>8'hc0 || (ukpdat[3:0]>=3 && ukpdat[3:0]<=5);
                        pending_game_x <= ukpdat[4];pending_game_a <= ukpdat[5];
                        pending_game_b <= ukpdat[6];pending_game_y <= ukpdat[7];
                    end
                    6: begin
                        pending_game_lb <= ukpdat[0];pending_game_rb <= ukpdat[1];
                        pending_game_sel <= ukpdat[6];pending_game_sta <= ukpdat[7];
                    end
                    endcase
                end else if (is_0810_0001) begin

                    // -------------------------------------------------
                    // VID:PID 0810:0001
                    // Verified report layout:
                    //   d[3] = X axis
                    //   d[4] = Y axis
                    //   d[5][7:4] = YBAX
                    //   d[6][5:4] = START/SELECT
                    //   d[6][1:0] = LB/RB
                    // -------------------------------------------------

                    case (rcvct)

                    3: begin
                        if (ukpdat < 8'h40)
                            {pending_game_l, pending_game_r} <= 2'b10;
                        else if (ukpdat > 8'hC0)
                            {pending_game_l, pending_game_r} <= 2'b01;
                        else
                            {pending_game_l, pending_game_r} <= 2'b00;
                    end

                    4: begin
                        if (ukpdat < 8'h40)
                            {pending_game_u, pending_game_d} <= 2'b10;
                        else if (ukpdat > 8'hC0)
                            {pending_game_u, pending_game_d} <= 2'b01;
                        else
                            {pending_game_u, pending_game_d} <= 2'b00;
                    end

                    5: begin
                        pending_game_x <= ukpdat[4];
                        pending_game_a <= ukpdat[5];
                        pending_game_b <= ukpdat[6];
                        pending_game_y <= ukpdat[7];
                    end

                    6: begin
                        pending_game_sel <= ukpdat[4];
                        pending_game_sta <= ukpdat[5];
                        pending_game_lb  <= ukpdat[0];
                        pending_game_rb  <= ukpdat[1];
                    end

                    endcase
                end else begin
                    // -------------------------------------------------
                    // Original TangCore generic gamepad parser
                    // -------------------------------------------------

                    case (rcvct)

                    0: begin
                        if (ukpdat[1:0] != 2'b10) begin
                            // for DualShock2 adapter,
                            // 2'b10 marks an irrelevant record
                            valid <= 1;
                        end else
                            valid <= 0;

                        if (ukpdat == 8'h00)
                            {pending_game_l, pending_game_r} <= 2'b10;

                        if (ukpdat == 8'h7f)
                            {pending_game_l, pending_game_r} <= 2'b00;

                        if (ukpdat == 8'hff)
                            {pending_game_l, pending_game_r} <= 2'b01;
                    end

                    1: begin
                        if (ukpdat == 8'h00)
                            {pending_game_u, pending_game_d} <= 2'b10;

                        if (ukpdat == 8'h7f)
                            {pending_game_u, pending_game_d} <= 2'b00;

                        if (ukpdat == 8'hff)
                            {pending_game_u, pending_game_d} <= 2'b01;
                    end

                    5: if (valid) begin
                        pending_game_x <= ukpdat[4];
                        pending_game_a <= ukpdat[5];
                        pending_game_b <= ukpdat[6];
                        pending_game_y <= ukpdat[7];
                    end

                    6: if (valid) begin
                        pending_game_sel <= ukpdat[4];
                        pending_game_sta <= ukpdat[5];
                        pending_game_lb  <= ukpdat[0];
                        pending_game_rb  <= ukpdat[1];
                    end

                    endcase
                end
            end
            rcvct <= rcvct + 1;
        end
    end
    if(~data_rdy && data_rdy_r && typ != 0)    // falling edge of ukp data ready
        report <= 1;
    if (conerr) begin                          // clear everything on connection error
        report <= 0;
        pending_game_l <= 0; pending_game_r <= 0; pending_game_u <= 0; pending_game_d <= 0;
        pending_game_a <= 0; pending_game_b <= 0; pending_game_x <= 0; pending_game_y <= 0;
        pending_game_sel <= 0; pending_game_sta <= 0;
        pending_game_lb <= 0; pending_game_rb <= 0;
    end
    end
end
always @(posedge usbclk) begin
 if(!host_reset_n || conerr || unplugged)begin
  game_l <= 0;
  game_r <= 0;
  game_u <= 0;
  game_d <= 0;
  game_a <= 0;
  game_b <= 0;
  game_x <= 0;
  game_y <= 0;
  game_sel <= 0;
  game_sta <= 0;
  game_lb <= 0;
  game_rb <= 0;
 end else if(!data_rdy && data_rdy_r && typ!=0)begin
  game_l <= pending_game_l;
  game_r <= pending_game_r;
  game_u <= pending_game_u;
  game_d <= pending_game_d;
  game_a <= pending_game_a;
  game_b <= pending_game_b;
  game_x <= pending_game_x;
  game_y <= pending_game_y;
  game_sel <= pending_game_sel;
  game_sta <= pending_game_sta;
  game_lb <= pending_game_lb;
  game_rb <= pending_game_rb;
 end
end

reg save_delayed;
reg connected_r;
always @(posedge usbclk) begin : response_recognition
    if (!host_reset_n || conerr || unplugged) begin
        save_delayed <= 0;
        connected_r <= 0;
        retry <= 0;
        typ <= 0;
        for (regs_i = 0; regs_i < 7; regs_i = regs_i + 1)
            regs[regs_i] <= 0;
    end else begin
    save_delayed <= save;
    retry <= 0;
    if (save && packet_valid && save_b < packet_length &&
        (save_r > 3 || packet_length >= 4)) begin
        regs[save_r] <= dat[save_b];
    end else if (save_delayed && ~save && save_r == 6) begin
        // falling edge of save for bInterfaceProtocol
        if (regs[4] == 3) begin  // bInterfaceClass. 3: HID, other: non-HID
            if (regs[5] == 1)    // bInterfaceSubClass. 1: Boot device
                typ <= regs[6] == 1 ? 1 : 2;     // bInterfaceProtocol. 1: keyboard, 2: mouse
            else
                typ <= 3;       // gamepad
        end else
            retry <= 1;  // not a HID device, wait a while (200ms) and retry
    end
    connected_r <= connected;
    if (~connected & connected_r) typ <= 0;   // clear device type on disconnect
    end
end

endmodule
