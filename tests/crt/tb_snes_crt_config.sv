`timescale 1ns/1ps
module tb_snes_crt_config;
    reg clk=0,pclk=0,resetn=0;
    always #11 clk=~clk;
    always #3 pclk=~pclk;
    reg [31:0] requested=0;
    reg frame_start=0;
    wire [31:0] active_config,applied_config;
    tc_crt_config dut(.*);
    reg [23:0] rgb_in=0;
    wire [23:0] rgb_out;
    tc_crt_bypass filter(.rgb_in(rgb_in),.rgb_out(rgb_out));
    reg [31:0] previous=0;
    reg boundary=0;
    integer checked=0;
    always @(negedge pclk)begin
        if(resetn)begin
            if(active_config!=previous && !boundary)$fatal(1,"configuration changed inside frame");
            previous=active_config;
        end else previous=0;
    end
    always @(posedge pclk)boundary<=frame_start;
    task automatic frame;
        @(negedge pclk);frame_start=1;@(negedge pclk);frame_start=0;
    endtask
    task automatic wait_applied(input [31:0] expected);
        integer tries;
        for(tries=0;tries<30;tries=tries+1)begin
            repeat(12)@(negedge pclk);frame();repeat(8)@(negedge clk);
            if(applied_config==expected)return;
        end
        $fatal(1,"mailbox did not converge to %h got %h",expected,applied_config);
    endtask
    initial begin
        repeat(4)@(negedge clk);resetn=1;
        requested=32'h001f1234;
        repeat(30)@(negedge pclk);
        if(active_config!=0||applied_config!=0)$fatal(1,"applied without a frame");
        frame();wait_applied(32'h001f1234);
        // Change the source repeatedly while one transaction is awaiting a frame.
        @(negedge clk);requested=32'h0001abcd;
        repeat(8)@(negedge clk);
        requested=32'h0007ff00;
        repeat(3)@(negedge clk);requested=32'h0019aa55;
        wait_applied(32'h0019aa55);
        // Bypass must preserve every possible 8-bit RGB combination sampled here,
        // with CRT enable cleared, including the prefetch compensation register.
        for(integer i=0;i<65536;i=i+1)begin
            rgb_in={8'(i),8'(i>>8),8'(i^8'hd3)};@(posedge pclk);#1;
            if(rgb_out!==rgb_in)$fatal(1,"bypass changed RGB");checked=checked+1;
        end
        @(negedge clk);resetn=0;repeat(4)@(negedge clk);
        if(active_config!=0||applied_config!=0)$fatal(1,"reset did not clear settings");
        resetn=1;requested=0;wait_applied(0);
        $display("CRT mailbox PASS: frame atomicity, coalescing, reset, bypass RGB samples=%0d",checked);$finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
