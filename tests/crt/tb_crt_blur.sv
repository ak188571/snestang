`timescale 1ns/1ps
module tb_crt_blur;
    reg pclk=0,resetn=0;
    always #3 pclk=~pclk;
    reg [23:0] rgb_in=0;
    reg first_pixel=0,last_pixel=0;
    reg [3:0] scan_depth=0;
    reg [31:0] config_active=0;
    wire [23:0] rgb_out;
    crt_filter dut(.*);
    reg [23:0] pixels[0:31];
    integer checks=0;
    function automatic [23:0] reference_rgb(input [23:0] l,c,r,input integer strength);
        integer denominator,result;
        begin
            denominator=strength==1?16:strength==2?8:4;
            for(integer channel=0;channel<3;channel++)begin
                result=strength==0?int'(c[channel*8+:8]):
                    (int'(l[channel*8+:8])+(denominator-2)*int'(c[channel*8+:8])+
                     int'(r[channel*8+:8])+denominator/2)/denominator;
                reference_rgb[channel*8+:8]=8'(result);
            end
        end
    endfunction
    task automatic line_check(input integer n,input integer strength,input bit enabled);
        reg [23:0] expected;
        config_active=(32'(strength)<<17)|(enabled?32'h10000:0);
        for(integer x=-3;x<n;x++)begin
            integer read_x;
            @(negedge pclk);
            read_x=enabled&&strength!=0?x+3:x;
            if(read_x<0)read_x=0;if(read_x>=n)read_x=n-1;
            rgb_in=pixels[read_x];first_pixel=x+1==0;last_pixel=x+1==n-1;
            #1;
            if(x>=0)begin
                expected=reference_rgb(pixels[x==0?x:x-1],pixels[x],pixels[x==n-1?x:x+1],enabled?strength:0);
                if(rgb_out!==expected)$fatal(1,"blur n=%0d x=%0d strength=%0d enable=%0d got=%h expected=%h",n,x,strength,enabled,rgb_out,expected);
                checks++;
            end
            @(posedge pclk);#1;
        end
    endtask
    initial begin
        repeat(3)@(negedge pclk);resetn=1;
        // Constant black/white, RGB impulses, alternating pixels, ramp, and noise.
        // Short lines and consecutive contrasting lines exercise both clamps.
        for(integer pattern=0;pattern<7;pattern++)begin
            for(integer n=1;n<=32;n++)begin
                for(integer x=0;x<n;x++)begin
                    case(pattern)
                        0:pixels[x]=0;
                        1:pixels[x]=24'hffffff;
                        2:pixels[x]=x==n/2?24'hff0000:0;
                        3:pixels[x]=x==n/2?24'h00ff01:0;
                        4:pixels[x]=x[0]?24'hffffff:0;
                        5:pixels[x]={8'(x*7),8'(255-x*5),8'(x*3)};
                        6:pixels[x]=24'($urandom);
                    endcase
                end
                for(integer strength=0;strength<4;strength++)begin
                    line_check(n,strength,1);line_check(n,strength,0);
                end
            end
        end
        @(negedge pclk);resetn=0;config_active=0;
        @(posedge pclk);#1;if(dut.palette_q!==0||dut.center!==0||dut.previous!==0||dut.blurred_q!==0)$fatal(1,"reset left stale samples");
        $display("CRT blur PASS: independent integer reference, 3 strengths, enable/strength bypass, per-channel rounding, black/white/impulses/alternation/ramp/noise, widths 1..32, edge clamps, reset; pixels=%0d",checks);
        $finish;
    end
    initial begin #1000000;$fatal(1,"blur timeout");end
endmodule
