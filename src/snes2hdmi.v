// NES video and sound to HDMI converter
// nand2mario, 2022.9

`timescale 1ns / 1ps

module snes2hdmi #(parameter CRT_STAGE1=0, CRT_BLUR=0, CRT_SCAN=0) (
	input clk,      // snes clock
	input resetn,

    // snes video and audio signals
    input dotclk,
    input hblank,
    input vblank,
    input [14:0] rgb5,
    input [8:0] xs, // {x,dotclk}
    input [8:0] ys, // {field,y}

    input [31:0] core_config,
    output [31:0] crt_config_applied,

    input overlay,
    input [31:0] osd_window,
    input osd_window_toggle,
    output osd_visible,

    output [7:0] overlay_x,
    output [7:0] overlay_y,
    input [14:0] overlay_color,

    input [15:0] audio_l,
    input [15:0] audio_r,
    input audio_ready,
    output audio_en,

    // frame-sync pause happens during snes_refresh
    input snes_refresh,

	// video clocks
	input clk_pixel,
	input clk_5x_pixel,
	input locked,

    output reg pause_snes_for_frame_sync,

    // output [7:0] led,

	// output signals
	output       tmds_clk_n,
	output       tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p
);

    localparam FRAMEWIDTH = 1280;       // 720P
    localparam FRAMEHEIGHT = 720;
    localparam TOTALWIDTH = 1650;
    localparam TOTALHEIGHT = 750;
    localparam SCALE = 5;
    localparam VIDEOID = 4;
    localparam VIDEO_REFRESH = 60.0;

    localparam IDIV_SEL_X5 = 3;
    localparam FBDIV_SEL_X5 = 54;
    localparam ODIV_SEL_X5 = 2;
    localparam DUTYDA_SEL_X5 = "1000";
    localparam DYN_SDIV_SEL_X5 = 2;
    
    localparam CLKFRQ = 74250;

    localparam AUDIO_BIT_WIDTH = 16;

    // video stuff
    wire [9:0] cy, frameHeight;
    wire [10:0] cx, frameWidth;
    reg r_active;
    wire [7:0] x, y;                    // SNES pixel position

    //
    // BRAM line buffer for 16 lines. Each pixel is 5:5:5 RGB
    // Each BRAM block holds 4 lines. So 16 lines needs 4 blocks.
    //
    localparam BUF_WIDTH = 5;        // 2 ^ BUF_WIDTH lines
    localparam BUF_SIZE = 1 << BUF_WIDTH;
    reg [14:0] mem [0:BUF_SIZE*256-1];
    reg [BUF_WIDTH+8-1:0] mem_portA_addr;
    reg [14:0] mem_portA_wdata;
    reg mem_portA_we;
    wire [BUF_WIDTH+8-1:0] mem_portB_addr;
    reg [14:0] mem_portB_rdata;
    reg mem_writeto = 1'b0;     // current line we are writing to. we read from the other line
   
    // We need to do a bit of synchronization as the SNES and HDMI run on separate clocks and they
    // do not align perfectly.
    // - Let SNES execute a bit faster (0.5%) than the HDMI stack. This way we always have enough pixels.
    // - For each frame, we let the SNES run until the first line is rendered, and written to line buffer.
    //   Then we pause the SNES and wait (through pause_snes_for_frame_sync) for HDMI to catch up.
    // - Once HDMI started the frame, start SNES again.
    reg sync_done = 1'b0;
    reg hdmi_first_line;
    reg pause_sync;     // pause for even number of cycles for PPU sdram access to stay in sync
    reg hdmi_first_line_r, hdmi_first_line_rr;
    always @(posedge clk) begin
        hdmi_first_line_r <= hdmi_first_line;
        hdmi_first_line_rr <= hdmi_first_line_r;
        if (pause_snes_for_frame_sync) pause_sync <= ~pause_sync;
        if (~sync_done) begin
            if (~pause_snes_for_frame_sync) begin
                if (ys[7:0] == 8'd1 && snes_refresh) begin      // halt SNES after first line is buffered
                    pause_snes_for_frame_sync <= 1'b1;
                    pause_sync <= 0;
                end
            end else if (hdmi_first_line_rr && pause_sync) begin                 // HDMI frame start, now resume SNES
                pause_snes_for_frame_sync <= 1'b0;
                sync_done <= 1'b1;
            end
        end else
            pause_snes_for_frame_sync <= 1'b0;
        if (ys[7:0] == 8'd200) sync_done <= 1'b0;               // reset sync_done for next frame
    end
    always @(posedge clk_pixel) begin
        if (cy == 0 && cx >= 11'd160)      
            hdmi_first_line <= 1;
        else
            hdmi_first_line <= 0;
    end

    // BRAM port A read/write
	always_ff @(posedge clk) begin
		if (mem_portA_we) begin
			mem[mem_portA_addr] <= mem_portA_wdata;
		end
	end

    // BRAM port B read
    always_ff @(posedge clk_pixel) begin
        mem_portB_rdata <= mem[mem_portB_addr];
    end

    integer j;
    initial begin
        // On power-up, fill line buffer with a gradient
        for (j = 0; j < 512; j=j+1) begin
            mem[j][14:10] = j;
            mem[j][9:5] = j;
            mem[j][4:0] = j;
        end
    end

    // 
    // Data input
    //
    reg r_dotclk, r_vblank, r_hblank;
    always @(posedge clk) begin
        r_dotclk <= dotclk;
        r_vblank <= vblank;
        mem_portA_we <= 1'b0;
        if (dotclk && ~r_dotclk && ~hblank && ~vblank && ys[7:0] < 224) begin       // on posedge of dotclk, read a pixel
            mem_portA_addr <= {ys[BUF_WIDTH-1:0], xs[8:1]};
            mem_portA_wdata <= rgb5;
            mem_portA_we <= 1'b1;
        end
    end

    always @(posedge clk) begin
        r_hblank <= hblank;
        if (hblank & ~r_hblank) begin       // flip active line on hblank
            mem_writeto <= ~mem_writeto;
        end
    end
    

    // HDMI TX audio - send 32K sampling rate audio
    // Hoarse sound issue: https://github.com/nand2mario/snestang/issues/16
    // SNES average framerate is 60.09881. So we need to pause the SNES a bit every frame to ensure 60 fps HDMI. 
    // For sound, that translate to about 8 samples pause time per frame. So we run our DSP a bit faster to 
    // buffer enough samples before the SNES pause.
    localparam AUDIO_OUT_RATE = 32000;
    localparam AUDIO_DELAY = CLKFRQ * 1000 / AUDIO_OUT_RATE / 2;
    reg [15:0] audio_sample_word [1:0];
    reg [$clog2(AUDIO_DELAY)-1:0] audio_divider;
    reg clk_audio;
    reg audio_rinc;
    wire audio_full, audio_empty;
    wire [31:0] audio_sample;

    always @(posedge clk_pixel) begin
        if (resetn) begin
            audio_rinc <= 0;
            if (audio_divider != AUDIO_DELAY - 1) 
                audio_divider <= audio_divider + 1;
            else begin 
                audio_divider <= 0;
                clk_audio = ~clk_audio;     // generate audio clock @ 32Khz
                // output audio sample on posedge clk_audio
                if (!clk_audio && !audio_empty) begin
                    {audio_sample_word[0], audio_sample_word[1]} <= audio_sample;
                    audio_rinc <= 1'b1;                    
                end
            end
        end
    end

    // Audio sample FIFO for 16 samples
    dual_clk_fifo #(.DATESIZE(32), .ADDRSIZE(4)) audio_fifo (
        .clk(clk), .wrst_n(1'b1), 
        .winc(audio_ready), .wdata({audio_l, audio_r}), .wfull(audio_full),
        .rclk(clk_pixel), .rrst_n(1'b1),
        .rinc(audio_rinc), .rdata(audio_sample), .rempty(audio_empty),
        .almost_full(), .almost_empty()
    );

    //
    // Video
    //
    reg [23:0] rgb;             // actual RGB output
    reg active;
    reg [7:0] xx;               // scaled-down pixel position
    reg [7:0] yy;
    reg [10:0] xcnt;
    reg [10:0] ycnt;            // fractional scaling counters
    reg [9:0] cy_r;
    wire [31:0] crt_config_active;
    wire blur_enabled=CRT_STAGE1 && CRT_BLUR && crt_config_active[16] && |crt_config_active[18:17];
    wire scan_enabled=CRT_STAGE1 && CRT_SCAN && crt_config_active[16] && |crt_config_active[20:19];
    // Current SNES scaler: 256/960 source pixels per output pixel. Three
    // output-pixel lookahead advances at most one source column (carry >=192).
    // Keep the exact original address when blur is inactive, including live writes.
    wire [7:0] xx_three=xx+(xcnt>=11'd192 ? 8'd1 : 8'd0);
    // One output-pixel lookahead for scanline without blur: 960-256=704.
    // The 160-pixel side margin primes the unchanged Y/line-buffer phase.
    wire [7:0] xx_one=xx+(xcnt>=11'd704 ? 8'd1 : 8'd0);
    assign mem_portB_addr = {yy[BUF_WIDTH-1:0], (blur_enabled?xx_three:scan_enabled?xx_one:xx)};
    // Audited SNES path captures only ys[7:0]<224 and scales those 224 rows
    // over 720 output rows. This describes that existing sampled raster; it
    // does not add overscan, half-dot or interlaced-field reconstruction.
    // Each output row spans 224/720 source-row units. Integrate a dark strip
    // of that width at the end of each sampled row; ycnt is the footprint's
    // start phase. All reachable phases are multiples of gcd(224,720)=16.
    function automatic [3:0] sampled_scan_depth(input [10:0] phase,input [1:0] level);
        reg [5:0] index;
        reg [4:0] weight;
        begin
            index=phase[9:4];
            if(index<=17)weight=0;
            else if(index<31)weight=5'(index-17);
            else weight=5'(45-index);
            case(level)
                1:sampled_scan_depth=weight<4?0:weight<11?1:2;
                2:sampled_scan_depth=weight<2?0:weight<6?1:weight<9?2:weight<13?3:4;
                3:case(weight)
                    0:sampled_scan_depth=0;
                    1,2:sampled_scan_depth=1;
                    3,4:sampled_scan_depth=2;
                    5,6:sampled_scan_depth=3;
                    7:sampled_scan_depth=4;
                    8,9:sampled_scan_depth=5;
                    10,11:sampled_scan_depth=6;
                    12,13:sampled_scan_depth=7;
                    default:sampled_scan_depth=8;
                endcase
                default:sampled_scan_depth=0;
            endcase
        end
    endfunction
    reg [3:0] scan_depth=0;
    always @(posedge clk_pixel)begin
        if(!resetn)scan_depth<=0;
        else scan_depth<=CRT_SCAN?sampled_scan_depth(ycnt,crt_config_active[20:19]):4'd0;
    end
    wire osd_pixel;
tc_osd_layer osd_layer(.pclk(clk_pixel),.resetn(resetn),.cx(cx),.cy(cy),
    .active(overlay),.window(osd_window),.window_toggle(osd_window_toggle),
    .x(overlay_x),.y(overlay_y),.pixel(osd_pixel),.visible(osd_visible));
    localparam XSTART = (1280 - 960) / 2;   // 960:720 = 4:3
    localparam XSTOP = (1280 + 960) / 2;

    // address calculation
    // Assume the video occupies fully on the Y direction, we are upscaling the video by `720/height`.
    // xcnt and ycnt are fractional scaling counters.
    always @(posedge clk_pixel) begin
        reg active_t;
        reg [10:0] xcnt_next;
        reg [10:0] ycnt_next;
        xcnt_next = xcnt + 256;
        ycnt_next = ycnt + 224;

        active_t = 0;
        if (cx == XSTART - 1) begin
            active_t = 1;
            active <= 1;
        end else if (cx == XSTOP - 1) begin
            active_t = 0;
            active <= 0;
        end

        if (active_t | active) begin        // increment xx
            xcnt <= xcnt_next;
            if (xcnt_next >= 960) begin
                xcnt <= xcnt_next - 960;
                xx <= xx + 1;
            end
        end

        cy_r <= cy;
        if (cy[0] != cy_r[0]) begin         // increment yy at new lines
            ycnt <= ycnt_next;
            if (ycnt_next >= 720) begin
                ycnt <= ycnt_next - 720;
                yy <= yy + 1;
            end
        end

        if (cx == 0) begin
            xx <= 0;
            xcnt <= 0;
        end
        
        if (cy == 0) begin
            yy <= 0;
            ycnt <= 0;
        end 

    end

    // Frame-applied settings. BGR555 conversion remains the original bit extension.
    wire [23:0] game_rgb_raw={mem_portB_rdata[4:0],3'b0,
        mem_portB_rdata[9:5],3'b0,mem_portB_rdata[14:10],3'b0};
    wire [23:0] game_rgb_crt;
    generate if(CRT_STAGE1)begin : crt_stage1
        tc_crt_config crt_config(.clk(clk),.pclk(clk_pixel),.resetn(resetn),
            .requested(core_config),.frame_start(cx==0 && cy==0),
            .active_config(crt_config_active),.applied_config(crt_config_applied));
        if(CRT_BLUR || CRT_SCAN)begin : blur_path
            crt_filter crt(.pclk(clk_pixel),.resetn(resetn),
                .rgb_in(game_rgb_raw),.config_active(crt_config_active &
                    (CRT_SCAN?32'hffffffff:~32'h00180000) & (CRT_BLUR?32'hffffffff:~32'h00060000)),
                .first_pixel(cx==(blur_enabled?XSTART-1:XSTART)),
                .last_pixel(cx==(blur_enabled?XSTOP-2:XSTOP-1)),.scan_depth(scan_depth),
                .rgb_out(game_rgb_crt));
        end else begin : bypass_path
            tc_crt_bypass crt(.rgb_in(game_rgb_raw),.rgb_out(game_rgb_crt));
        end
    end else begin : no_crt
        assign crt_config_active=0;
        assign crt_config_applied=0;
        assign game_rgb_crt=game_rgb_raw;
    end endgenerate

    // calc rgb value to hdmi
    always @(posedge clk_pixel) begin
        if (active) begin
            if (osd_pixel)
                rgb <= {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};       // BGR5 to RGB8
            else
                rgb <= game_rgb_crt;
        end else
            rgb <= 24'h303030;
    end

    // HDMI output.
    logic[2:0] tmds;

    hdmi #( .VIDEO_ID_CODE(VIDEOID), 
            .DVI_OUTPUT(0), 
            .VIDEO_REFRESH_RATE(VIDEO_REFRESH),
            .IT_CONTENT(1),
            .AUDIO_RATE(AUDIO_OUT_RATE), 
            .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
            .START_X(0),
            .START_Y(0) )

    hdmi( .clk_pixel_x5(clk_5x_pixel), 
          .clk_pixel(clk_pixel), 
          .clk_audio(clk_audio),
          .rgb(rgb), 
          .reset( ~resetn ),
          .audio_sample_word(audio_sample_word),
          .tmds(tmds), 
          .tmds_clock(tmdsClk), 
          .cx(cx), 
          .cy(cy),
          .frame_width( frameWidth ),
          .frame_height( frameHeight ) );

    // Gowin LVDS output buffer
    ELVDS_OBUF tmds_bufds [3:0] (
        .I({clk_pixel, tmds}),
        .O({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n})
    );

endmodule
