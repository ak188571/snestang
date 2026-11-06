`timescale 1ns/1ps
// Full real SNES scaler/buffer/audio/OSD comparison with a published baseline.
module tb_snes_crt_blur_video;
    reg clk=0,pclk=0,resetn=0;
    always #23 clk=~clk;
    always #7 pclk=~pclk;
    reg dotclk=0,run_video=1;
    reg [8:0] xs=0,ys=0;
    reg [14:0] color=0;
    always @(posedge clk)if(run_video)begin
        dotclk<=~dotclk;
        if(dotclk)begin
            xs<=xs+1'b1;color<=color+15'd37;
            if(xs==511)ys<=ys+1'b1;
        end
    end
    reg overlay=0,toggle=0;
    reg [31:0] window=32'h01011010,requested=0;
    wire [7:0] nx,ny,bx,by;
    wire nv,bv,npause,bpause;
    wire [31:0] applied;
    snes2hdmi #(.CRT_STAGE1(1),.CRT_BLUR(1)) current(
        .clk(clk),.resetn(resetn),.dotclk(dotclk),.hblank(xs>509),.vblank(ys[7:0]>239),
        .rgb5(color),.xs(xs),.ys(ys),.core_config(requested),.crt_config_applied(applied),
        .overlay(overlay),.osd_window(window),.osd_window_toggle(toggle),.osd_visible(nv),
        .overlay_x(nx),.overlay_y(ny),.overlay_color(15'h4a53),
        .audio_l(16'h1234),.audio_r(16'h5678),.audio_ready(dotclk),.snes_refresh(1'b1),
        .clk_pixel(pclk),.clk_5x_pixel(pclk),.locked(1'b1),.pause_snes_for_frame_sync(npause));
    baseline_snes2hdmi baseline(
        .clk(clk),.resetn(resetn),.dotclk(dotclk),.hblank(xs>509),.vblank(ys[7:0]>239),
        .rgb5(color),.xs(xs),.ys(ys),.overlay(overlay),.osd_window(window),.osd_window_toggle(toggle),.osd_visible(bv),
        .overlay_x(bx),.overlay_y(by),.overlay_color(15'h4a53),
        .audio_l(16'h1234),.audio_r(16'h5678),.audio_ready(dotclk),.snes_refresh(1'b1),
        .clk_pixel(pclk),.clk_5x_pixel(pclk),.locked(1'b1),.pause_snes_for_frame_sync(bpause));

    function automatic [23:0] expand(input [14:0] bgr);
        return {bgr[4:0],3'b0,bgr[9:5],3'b0,bgr[14:10],3'b0};
    endfunction
    function automatic [23:0] reference_rgb(input [23:0] l,c,r,input integer level);
        integer denominator,result;
        begin
            denominator=level==1?16:level==2?8:4;
            for(integer channel=0;channel<3;channel++)begin
                result=level==0?int'(c[channel*8+:8]):
                    (int'(l[channel*8+:8])+(denominator-2)*int'(c[channel*8+:8])+
                     int'(r[channel*8+:8])+denominator/2)/denominator;
                reference_rgb[channel*8+:8]=8'(result);
            end
        end
    endfunction
    reg [23:0] center,left;
    reg active_sample,osd_sample;
    reg [10:0] x_sample;
    reg [31:0] config_sample;
    always @(posedge pclk)begin
        left<=center;center<=expand(baseline.mem_portB_rdata);
        active_sample<=baseline.active;osd_sample<=baseline.osd_pixel;
        x_sample<=baseline.cx;config_sample<=current.crt_config_active;
    end
    integer pixels=0,osd_pixels=0,frames=0,seen[0:3]='{default:0};
    initial begin
        reg [23:0] expected,right;
        integer level;
        repeat(10)@(negedge clk);resetn=1;
        for(integer k=0;k<14500000;k++)begin
            @(negedge pclk);
            right=expand(baseline.mem_portB_rdata);
            level=config_sample[16]?int'(config_sample[18:17]):0;
            expected=!active_sample?24'h303030:osd_sample?expand(15'h4a53):
                reference_rgb(x_sample==160?center:left,center,x_sample==1119?center:right,level);
            if(k>3&&current.rgb!==expected)$fatal(1,"SNES centered FIR mismatch x=%0d y=%0d level=%0d got=%h expected=%h",x_sample,current.cy,level,current.rgb,expected);
            if(k>3&&level==0)begin
                if(current.rgb!==baseline.rgb)$fatal(1,"bypass/ignored scan bits changed live RGB phase");
                if(current.mem_portB_addr!==baseline.mem_portB_addr)$fatal(1,"bypass read address changed");
            end
            if({nx,ny,nv}!=={bx,by,bv})$fatal(1,"OSD changed");
            if(current.mem_portA_we!==baseline.mem_portA_we||current.mem_portA_addr!==baseline.mem_portA_addr)$fatal(1,"buffer writes changed");
            if(npause!==bpause)$fatal(1,"frame-sync pause changed");
            if(current.audio_sample!==baseline.audio_sample||current.clk_audio!==baseline.clk_audio)$fatal(1,"audio changed");
            pixels++;if(current.osd_pixel)osd_pixels++;
            if(active_sample&&!osd_sample)seen[level]++;
            if(current.cx==0&&current.cy==0)begin
                frames++;overlay=frames%3!=0;
                case(frames%5)
                    0:window=32'h08061010;
                    1:window=32'h01011010;
                    2:window=32'h0f011010;
                    3:window=32'h010b1010;
                    4:window=32'h0f0b1010;
                endcase
                toggle=~toggle;
            end
            if(k==500000)requested=32'h001e1234; // enable OFF with all requests
            if(k==2000000)requested=32'h00191234; // blur OFF, scan request ignored
            // Spatial FIR comparison is frozen to remove ambiguous live BRAM
            // collisions. Bypass before/after is tested with continuous writes.
            if(k==3000000)run_video=0;
            if(k==3250000)requested=32'h001b1234;
            if(k==5000000)requested=32'h001d1234;
            if(k==7000000)requested=32'h001f1234;
            if(k==9000000)requested=32'h00191234;
            if(k==10500000)begin requested=32'h001e1234;run_video=1;end
            if(k==12500000)requested=32'h00011234;
        end
        for(integer v=0;v<4;v++)if(seen[v]<10000)$fatal(1,"level %0d not covered",v);
        if(osd_pixels<10000)$fatal(1,"OSD coverage missing");
        $display("SNES blur video PASS: %0d pixels, independent pinned SNES RGB reference, 3 strengths, edge clamps, exact live bypass/phase, ignored scan requests, five OSD windows, audio/frame sync unchanged",pixels);
        $finish;
    end
endmodule
