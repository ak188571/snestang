`timescale 1ns/1ps
module tb_snes_input_release;
    reg clk=0,blocked=1,strobe=0,serial_clock=1;
    reg [15:0] buttons=0;
    wire serial_data;
    always #5 clk=~clk;
    controller_adapter
`ifdef BLOCK_SAFE
        #(.BLOCK_OSD(1))
`endif
        dut(.clk(clk),.snes_buttons(buttons),.snes_joy_strb(strobe),
            .snes_joy_clk(serial_clock),.snes_joy_di(serial_data)
`ifdef BLOCK_SAFE
            ,.input_block(blocked)
`endif
        );
    wire game_data=blocked?1'b1:serial_data;
    task automatic shift;
        @(negedge clk);serial_clock=0;
        repeat(3)@(negedge clk);serial_clock=1;
        repeat(3)@(negedge clk);
    endtask
    initial begin
        for(integer bit_index=0;bit_index<12;bit_index++)begin
            blocked=1;buttons=16'(1<<bit_index);strobe=1;
            repeat(4)@(negedge clk);strobe=0;
            repeat(bit_index)shift();
            // OSD closes during an existing serial read, before another latch.
            buttons=0;blocked=0;
            repeat(2)@(negedge clk);
            if(game_data!==1'b1)$fatal(1,"stale OSD button %0d leaked after release",bit_index);
        end
        // The next normal latch must still carry real game input.
        buttons=1;strobe=1;repeat(4)@(negedge clk);strobe=0;
        if(game_data!==1'b0)$fatal(1,"normal gameplay button lost");
        $display("SNES serial input PASS: all 12 stale held bits flushed during OSD, neutral partial-read exit and normal next latch");
        $finish;
    end
endmodule
