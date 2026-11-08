// Integer-clock 8N1 UART. Console138K's 80 MHz PLL output gives 40/10
// clocks per bit at 2/8 Mbit/s. RX validates start/stop with three samples.
module tc_uart_phy #(parameter integer CLOCK_HZ=80000000)(
    input logic clk,resetn,fast,flush,
    input logic rx,
    output logic [7:0] rx_data,
    output logic rx_valid,rx_error,
    input logic [7:0] tx_data,
    input logic tx_valid,
    output wire tx_ready,tx_idle,
    output wire tx
);
    localparam integer SLOW_DIV=CLOCK_HZ/2000000,FAST_DIV=CLOCK_HZ/8000000;
    initial begin
        if(CLOCK_HZ%8000000!=0 || FAST_DIV<8)$fatal(1,"UART clock must provide >=8 integer clocks/bit");
    end
    wire [7:0] period=fast?FAST_DIV:SLOW_DIV;
    logic [1:0] rx_sync=2'b11 /* synthesis syn_preserve=1 */;
    always_ff @(posedge clk)rx_sync<={rx_sync[0],rx};
    logic [1:0] rstate=0;
    logic [7:0] rcounter=0;
    logic [1:0] votes=0;
    logic [2:0] rbit=0;
    logic [7:0] rshift=0;
    always_ff @(posedge clk)begin
        rx_valid<=0;rx_error<=0;
        if(!resetn||flush)begin rstate<=0;rcounter<=0;votes<=0;end
        else if(rstate==0)begin
            if(!rx_sync[1])begin rstate<=1;rcounter<=0;votes<=0;rbit<=0;end
        end else begin
            rcounter<=rcounter+1'b1;
            if(rcounter==period/2-1)votes<={1'b0,rx_sync[1]};
            if(rcounter==period/2)votes<=votes+rx_sync[1];
            if(rcounter==period/2+1)begin
                if(rstate==1 && votes+{1'b0,rx_sync[1]}>=2)begin rstate<=0;rx_error<=1;end
                if(rstate==2)rshift[rbit]<=votes+{1'b0,rx_sync[1]}>=2;
                if(rstate==3)begin
                    if(votes+{1'b0,rx_sync[1]}>=2)begin rx_data<=rshift;rx_valid<=1;end
                    else rx_error<=1;
                    // Re-arm in the stop bit. Waiting for its full period
                    // accumulates a clock of drift on back-to-back frames.
                    rstate<=0;
                end
            end
            if(rcounter==period-1)begin
                rcounter<=0;
                if(rstate==1)rstate<=2;
                if(rstate==2)begin if(rbit==7)rstate<=3;else rbit<=rbit+1'b1;end
                if(rstate==3)rstate<=0;
            end
        end
    end
    logic [9:0] tshift=10'h3ff;
    logic [3:0] tleft=0;
    logic [7:0] tcounter=0;
    assign tx_ready=tleft==0;
    assign tx_idle=tleft==0;
    assign tx=tleft==0?1'b1:tshift[0];
    always_ff @(posedge clk)begin
        if(!resetn||flush)begin tleft<=0;tcounter<=0;tshift<=10'h3ff;end
        else if(tleft==0)begin
            if(tx_valid)begin tshift<={1'b1,tx_data,1'b0};tleft<=10;tcounter<=0;end
        end else if(tcounter==period-1)begin
            tcounter<=0;tshift<={1'b1,tshift[9:1]};tleft<=tleft-1'b1;
        end else tcounter<=tcounter+1'b1;
    end
endmodule
