`timescale 1ns/1ps
// Compare against the published SNES path, with an independent geometric
// overlap/gain reference. Never use the new depth/prefetch to predict RGB.
module tb_snes_crt_scan_video;
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
    snes2hdmi #(.CRT_STAGE1(1),.CRT_BLUR(1),.CRT_SCAN(1)) current(
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
    function automatic integer reference_depth(input integer row,input integer level);
        integer phase,lo,hi,overlap,maximum;
        begin
            phase=(row*224)%720;
            lo=phase>496?phase:496;
            hi=phase+224<720?phase+224:720;
            overlap=hi>lo?hi-lo:0;
            maximum=level==0?0:level==1?2:level==2?4:8;
            return (maximum*overlap+112)/224;
        end
    endfunction
    function automatic [23:0] reference_rgb(input [23:0] l,c,r,input integer blur,depth);
        integer denominator,value;
        begin
            denominator=blur==1?16:blur==2?8:4;
            for(integer channel=0;channel<3;channel++)begin
                value=blur==0?int'(c[channel*8+:8]):
                    (int'(l[channel*8+:8])+(denominator-2)*int'(c[channel*8+:8])+
                     int'(r[channel*8+:8])+denominator/2)/denominator;
                reference_rgb[channel*8+:8]=8'((value*(16-depth)+8)/16);
            end
        end
    endfunction
    reg [23:0] center,left;
    reg active_sample,osd_sample;
    reg [10:0] x_sample;
    reg [9:0] y_sample;
    reg [31:0] config_sample;
    always @(posedge pclk)begin
        left<=center;center<=expand(baseline.mem_portB_rdata);
        active_sample<=baseline.active;osd_sample<=baseline.osd_pixel;
        x_sample<=baseline.cx;y_sample<=baseline.cy;
        config_sample<=current.crt_config_active;
    end
    integer pixels=0,osd_pixels=0,frames=0,seen[0:3][0:3]='{default:'{default:0}};
    initial begin
        reg [23:0] expected,right;
        integer blur,scan,depth,total,index;
        // All 720 output-row phases; compare LUT to geometric overlap and
        // verify total darkness 224*D, independently of implementation LUT.
        for(integer level=0;level<4;level++)begin
            total=0;
            for(integer row=0;row<720;row++)begin
                depth=reference_depth(row,level);total+=depth;
                if(current.sampled_scan_depth(11'((row*224)%720),2'(level))!==4'(depth))
                    $fatal(1,"sampled row overlap mismatch row=%0d level=%0d",row,level);
            end
            if(total!=(level==0?0:level==1?448:level==2?896:1792))$fatal(1,"integrated scan strength mismatch");
        end
        repeat(10)@(negedge clk);resetn=1;
        for(integer k=0;k<47000000;k++)begin
            @(negedge pclk);
            right=expand(baseline.mem_portB_rdata);
            blur=config_sample[16]?int'(config_sample[18:17]):0;
            scan=config_sample[16]?int'(config_sample[20:19]):0;
            depth=reference_depth(int'(y_sample),scan);
            expected=!active_sample?24'h303030:osd_sample?expand(15'h4a53):
                reference_rgb(x_sample==160?center:left,center,x_sample==1119?center:right,blur,depth);
            if(k>3&&current.rgb!==expected)$fatal(1,"SNES scan/FIR mismatch x=%0d y=%0d blur=%0d scan=%0d depth=%0d got=%h expected=%h",x_sample,y_sample,blur,scan,depth,current.rgb,expected);
            if(k>3&&blur==0&&scan==0)begin
                if(current.rgb!==baseline.rgb)$fatal(1,"OFF changed live RGB phase");
                if(current.mem_portB_addr!==baseline.mem_portB_addr)$fatal(1,"OFF changed read address");
            end
            if({nx,ny,nv}!=={bx,by,bv})$fatal(1,"OSD changed");
            if(current.mem_portA_we!==baseline.mem_portA_we||current.mem_portA_addr!==baseline.mem_portA_addr||current.mem_portA_wdata!==baseline.mem_portA_wdata)$fatal(1,"source sampling changed");
            if(npause!==bpause)$fatal(1,"frame-sync pause changed");
            if(current.audio_sample!==baseline.audio_sample||current.clk_audio!==baseline.clk_audio)$fatal(1,"audio changed");
            pixels++;if(current.osd_pixel)osd_pixels++;
            if(active_sample&&!osd_sample&&y_sample<720)begin
                seen[blur][scan]++;
                if(current.yy!==8'((int'(y_sample)*224)/720))$fatal(1,"sampled Y mapping changed");
            end
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
            if(k==500000)requested=32'h001e1234; // master OFF, all requests
            // Freeze writes for deterministic spatial comparison. OFF paths
            // before/after retain the exact original simultaneous write timing.
            if(k==3000000)run_video=0;
            if(k>=3250000&&k<=40750000&&(k-3250000)%2500000==0)begin
                index=(k-3250000)/2500000;
                requested=32'h00011234|(32'(index%4)<<17)|(32'(index/4)<<19);
            end
            if(k==43500000)begin requested=32'h001e1234;end
            if(k==45000000)begin run_video=1;end
        end
        for(integer b=0;b<4;b++)for(integer s=0;s<4;s++)
            if(seen[b][s]<10000)$fatal(1,"combination blur=%0d scan=%0d not covered",b,s);
        if(osd_pixels<10000)$fatal(1,"OSD coverage missing");
        $display("SNES scan video PASS: %0d pixels, 16 blur/scan combinations, 720 geometric row phases and integrated darkness, edges/position/live OFF, five OSD windows, source sampling/audio/frame sync unchanged",pixels);
        $finish;
    end
endmodule
