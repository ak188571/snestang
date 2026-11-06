`timescale 1ns/1ps
module tb_snes_crt_uart #(parameter integer FREQ=32000000, EXPECT_BLUR=0, parameter real HALF_PERIOD=5.0, BIT_NS=160.0);
    reg clk=0,hclk=0,resetn=0;
    always #(HALF_PERIOD) clk=~clk;always #2 hclk=~hclk;
    reg uart_rx=1;
    wire uart_tx,overlay,osd_input_block;
    reg [11:0] joy1=0,joy2=0;
    wire [31:0] core_config,crt_config_applied,active_config;
    reg frame_start=0;
    iosys_bl616 #(.FREQ(FREQ),.SUPPORT_CRT(1),.SUPPORT_RESTART(1),.SUPPORT_BLUR(EXPECT_BLUR)) dut(
        .clk(clk),.hclk(hclk),.resetn(resetn),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .overlay(overlay),.osd_visible(1'b0),.osd_input_block(osd_input_block),
        .overlay_x(8'b0),.overlay_y(8'b0),.joy1(joy1),.joy2(joy2),
        .core_config(core_config),.crt_config_applied(crt_config_applied),
        .mgmt_readdata(16'b0),.fdd_request(2'b0));
    tc_crt_config config_path(.clk(clk),.pclk(hclk),.resetn(resetn),
        .requested(core_config),.frame_start(frame_start),
        .active_config(active_config),.applied_config(crt_config_applied));
    wire [7:0] byte_out;
    wire byte_ready;
    async_receiver #(.ClkFrequency(FREQ),.Baud(2000000)) monitor(
        .clk(clk),.RxD(uart_tx),.RxD_data(byte_out),.RxD_data_ready(byte_ready));
    byte unsigned received[$];
    integer burst_start;
    always @(posedge clk)if(byte_ready)received.push_back(byte_out);
    task automatic send_byte(input byte unsigned b);
        @(negedge clk);uart_rx=0;#(BIT_NS);
        for(integer k=0;k<8;k=k+1)begin uart_rx=b[k];#(BIT_NS);end
        uart_rx=1;#(2*BIT_NS);
    endtask
    task automatic header(input byte unsigned len,input byte unsigned command);
        send_byte(8'haa);send_byte(0);send_byte(len);send_byte(command);
    endtask
    task automatic status(input [31:0] expected);
        integer from_byte;
        reg found;
        from_byte=received.size();header(1,8'h12);repeat(2500)@(negedge clk);
        found=0;
        for(integer k=from_byte;k+7<received.size();k=k+1)
            if(received[k]==8'haa&&received[k+1]==0&&received[k+2]==5&&received[k+3]==8'h12)begin
                if({received[k+4],received[k+5],received[k+6],received[k+7]}!==expected)
                    $fatal(1,"bad applied snapshot expected=%h got=%h",expected,{received[k+4],received[k+5],received[k+6],received[k+7]});
                found=1;
            end
        if(!found)$fatal(1,"status reply missing");
    endtask
    initial begin
        repeat(10)@(negedge clk);resetn=1;repeat(100)@(negedge clk);
        header(2,8'h08);send_byte(0);repeat(100)@(negedge clk);
        if(osd_input_block)$fatal(1,"input did not release");
        joy1=12'h144;#1;if(!osd_input_block)$fatal(1,"OSD2 chord leaked with extra A");
        repeat(4)@(negedge clk);joy1=0;repeat(5)@(negedge clk);
        if(osd_input_block)$fatal(1,"chord release stuck");
        joy2=12'h084;#1;if(osd_input_block)$fatal(1,"P2 claimed OSD ownership");
        // Keep a simultaneous joystick notification queued while a reply is requested.
        header(5,3);send_byte(0);send_byte(8'h1b);send_byte(8'h12);send_byte(8'h34);
        repeat(100)@(negedge clk);
        if(core_config!==32'h001b1234)$fatal(1,"UART config was not assembled");
        status(0); // no frame boundary, so no application yet
        @(negedge hclk);frame_start=1;@(negedge hclk);frame_start=0;
        repeat(12)@(negedge clk);status(32'h001b1234);
        header(6,3);send_byte(8'hde);send_byte(8'had);send_byte(8'hbe);send_byte(8'hef);send_byte(0);
        repeat(100)@(negedge clk);
        if(core_config!==32'h001b1234)$fatal(1,"wrong-length packet changed config");
        // BL616 polls status and immediately sends settings/drawing commands.
        // TX must never suspend RX or the next command header is silently lost.
        header(1,8'h12);
        header(5,3);send_byte(0);send_byte(1);send_byte(0);send_byte(0);
        repeat(2500)@(negedge clk);
        if(core_config!==32'h00010000)$fatal(1,"status reply blocked following config packet");
        // Keep the long capability reply active; queue more status requests,
        // write OSD text, and change config concurrently. TX type stays stable.
        burst_start=received.size();header(1,2);
        header(1,8'h12);header(1,8'h12);
        header(3,4);send_byte(7);send_byte(9);
        header(4,5);send_byte("A");send_byte("B");send_byte("C");
        header(5,3);send_byte(0);send_byte(8'h19);send_byte(0);send_byte(0);
        repeat(20000)@(negedge clk);
        if(core_config!==32'h00190000||dut.cursor_x!==10||dut.cursor_y!==9||dut.char_wr!=="C")
            $fatal(1,"long response blocked config or drawing packet");
        begin
            bit queued_status=0;
            for(integer k=burst_start;k+7<received.size();k++)
                if(received[k]==8'haa&&received[k+1]==0&&received[k+2]==5&&received[k+3]==8'h12)begin
                    if({received[k+4],received[k+5],received[k+6],received[k+7]}!==32'h001b1234)
                        $fatal(1,"queued status was torn or acknowledged before a frame");
                    queued_status=1;
                end
            if(!queued_status)$fatal(1,"queued status response lost behind long reply");
        end
        begin
            string reply="";
            bit marker=0,blur_marker=0,scan_marker=0;
            for(integer k=0;k<received.size();k=k+1)begin
                reply={reply,received[k]};
                if(k>=6&&{received[k-6],received[k-5],received[k-4],received[k-3],received[k-2],received[k-1],received[k]}=="CRTSTG1")marker=1;
                if(k>=6&&{received[k-6],received[k-5],received[k-4],received[k-3],received[k-2],received[k-1],received[k]}=="CRTBLR1")blur_marker=1;
                if(k>=6&&{received[k-6],received[k-5],received[k-4],received[k-3],received[k-2],received[k-1],received[k]}=="CRTSCN1")scan_marker=1;
            end
            if(!marker||blur_marker!=(EXPECT_BLUR!=0)||scan_marker)$fatal(1,"stage capability not transmitted");
        end
        // A previous setting can already be in the mailbox. Allow it to apply,
        // then the latest coalesced value at a subsequent frame boundary.
        repeat(3)begin
            @(negedge hclk);frame_start=1;@(negedge hclk);frame_start=0;
            #(BIT_NS);
        end
        status(32'h00190000);
        for(integer value=0;value<32;value++)begin
            header(5,3);send_byte(8'ha5);send_byte(8'he0|8'(value));send_byte(8'h12);send_byte(8'h34);
            repeat(3)begin
                repeat(20)@(negedge clk);
                @(negedge hclk);frame_start=1;@(negedge hclk);frame_start=0;
            end
            repeat(20)@(negedge clk);status(32'ha5e01234|(32'(value)<<16));
        end
        $display("CRT UART PASS: real serial packets, frame-applied readback, packet length guard, capability, immediate chord blocking, P1 ownership");$finish;
    end
    initial begin #20000000;$fatal(1,"UART timeout");end
endmodule
