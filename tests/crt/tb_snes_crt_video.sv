`timescale 1ns/1ps
// Full real SNES scaler/buffer/audio/OSD comparison with a published baseline.
module tb_snes_crt_video;
    reg clk=0,pclk=0,resetn=0;
    always #23 clk=~clk;
    always #7 pclk=~pclk;
    reg dotclk=0;
    reg [8:0] xs=0,ys=0;
    reg [14:0] color=0;
    always @(posedge clk)begin
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
    snes2hdmi #(.CRT_STAGE1(1)) current(
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
    integer pixels=0,osd_pixels=0,frames=0,seen[0:31]='{default:0};
    initial begin
        repeat(10)@(negedge clk);resetn=1;
        for(integer k=0;k<44000000;k++)begin
            @(negedge pclk);
            if(current.rgb!==baseline.rgb)$fatal(1,"bypass RGB/phase mismatch x=%d y=%d",current.cx,current.cy);
            if({nx,ny,nv}!=={bx,by,bv})$fatal(1,"OSD changed");
            if(current.mem_portB_addr!==baseline.mem_portB_addr)$fatal(1,"buffer read timing changed");
            if(current.mem_portA_we!==baseline.mem_portA_we||current.mem_portA_addr!==baseline.mem_portA_addr)$fatal(1,"buffer writes changed");
            if(npause!==bpause)$fatal(1,"frame-sync pause changed");
            if(current.audio_sample!==baseline.audio_sample||current.clk_audio!==baseline.clk_audio)$fatal(1,"audio changed");
            pixels++;if(current.osd_pixel)osd_pixels++;
            if(current.cx==0&&current.cy==0)begin
                frames++;seen[(current.crt_config_active>>16)&31]++;
                requested=(32'ha5e01234&~32'h001f0000)|((32'(frames)%32)<<16);
                overlay=frames%3!=0;
                case(frames%5)
                    0:window=32'h08061010; // center
                    1:window=32'h01011010; // top left
                    2:window=32'h0f011010; // top right
                    3:window=32'h010b1010; // bottom left
                    4:window=32'h0f0b1010; // bottom right
                endcase
                toggle=~toggle;
            end
        end
        for(integer v=0;v<32;v++)if(seen[v]==0)$fatal(1,"config %d not covered",v);
        if(osd_pixels<10000)$fatal(1,"OSD coverage missing");
        $display("SNES bypass PASS: %0d pixels, all 32 configurations, five windows, continuous live writes, source Y field/239 rows, RGB/phase/margins/OSD/audio/frame-sync unchanged",pixels);
        $finish;
    end
endmodule
