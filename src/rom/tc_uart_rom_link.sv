// UART transport adapter. Byte transaction/CRC/retry semantics live in the
// receiver, and the core adapter uses an acknowledged, held-data mailbox.
module tc_uart_rom_link #(parameter integer CLOCK_HZ=80000000)(
    input logic clk,resetn,input logic uart_rx,output wire uart_tx,
    input logic spi_clk,spi_resetn,
    input wire spi_cs_n,spi_sck,spi_mosi, output logic spi_selected=0,
    output wire legacy_hold,game_hold,
    output wire sink_req,output wire [7:0] sink_op,
    output wire [31:0] sink_offset,sink_total,sink_digest,
    output wire [10:0] sink_count,output wire [1:0] sink_bank,
    input logic sink_done,sink_ok,mem_clk,input logic [1:0] mem_bank,
    input logic [9:0] mem_address,output wire [7:0] mem_data
);
    logic fast=0,flush=0,fault=0;
    logic [31:0] guard_count=0,idle_count=0;
    wire rate_pulse,owned,processing,activity,end_verified;
    wire [31:0] rate_value;
    logic requested_fast=0;
    logic rate_ready=1;
    wire [7:0] rx_data,tx_data;
    wire rx_valid,rx_error,tx_valid,tx_ready,tx_idle;
    // GPIO28 is held low throughout SPI ownership. 512 clocks at 80 MHz
    // exceed the longest low interval of a legal 2 or 8 Mbit/s UART byte.
    // A watchdog may invalidate a session but must never route ongoing SCK
    // traffic into native JTAG. Only release of GPIO28 ends pin ownership.
    logic [1:0] select_sync=3;
    logic [8:0] low_ticks=0;
    always_ff @(posedge clk) begin
        select_sync <= {select_sync[0],uart_rx};
        if (!resetn || select_sync[1]) begin
            low_ticks <= 0;
            spi_selected <= 0;
        end else if (&low_ticks) spi_selected <= 1;
        else low_ticks <= low_ticks + 1'b1;
    end
    wire [7:0] spi_byte;
    wire spi_valid,spi_overflow;
    tc_spi_clock_crossing spi_crossing(
        .sample_clk(spi_clk),.sample_resetn(spi_resetn),.clk(clk),.resetn(resetn),
        .owned(spi_selected),.cs_n(spi_cs_n),.sck(spi_sck),.mosi(spi_mosi),
        .byte_data(spi_byte),.byte_valid(spi_valid),.overflow(spi_overflow));
    assign legacy_hold=owned||!rate_ready;
    tc_uart_phy #(.CLOCK_HZ(CLOCK_HZ)) phy(
        .clk(clk),.resetn(resetn),.fast(fast),.flush(flush),.rx(uart_rx || spi_selected),
        .rx_data(rx_data),.rx_valid(rx_valid),.rx_error(rx_error),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.tx_idle(tx_idle),.tx(uart_tx));
    tc_rom_receiver #(.CLOCK_HZ(CLOCK_HZ)) engine(
        .clk(clk),.resetn(resetn),.transport_fault(fault || spi_overflow),.rx_data(spi_selected ? spi_byte : rx_data),
        .rx_valid(rate_ready && (spi_selected ? (spi_valid && fast && owned) : rx_valid)),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.tx_idle(tx_idle),
        .link_at_base(!fast),.link_available(rate_ready),.rate_pulse(rate_pulse),.rate_value(rate_value),
        .owned(owned),.hold_reset(game_hold),.processing(processing),.end_verified(end_verified),.activity(activity),
        .sink_req(sink_req),.sink_op(sink_op),.sink_offset(sink_offset),.sink_total(sink_total),.sink_digest(sink_digest),
        .sink_count(sink_count),.sink_bank(sink_bank),.sink_done(sink_done),.sink_ok(sink_ok),
        .mem_clk(mem_clk),.mem_bank(mem_bank),.mem_address(mem_address),.mem_data(mem_data));
    always_ff @(posedge clk)begin
        flush<=0;fault<=0;
        if(!resetn)begin fast<=0;guard_count<=0;idle_count<=0;requested_fast<=0;rate_ready<=1;end
        else begin
            // Keep the 32-bit guard counter out of the receive/command cone.
            if(rate_pulse)begin guard_count<=CLOCK_HZ/250;requested_fast<=rate_value==8000000;rate_ready<=0;end
            else if(guard_count!=0)begin
                guard_count<=guard_count-1'b1;
                if(guard_count==1)begin fast<=requested_fast;flush<=1;rate_ready<=1;end
            end
            if(!owned||processing||activity||!rate_ready)idle_count<=0;
            // END may spend 10 seconds waiting for a lost ACK at the host.
            // Keep verified data retryable for 12 seconds; other idle states
            // still return to the base rate after one second.
            else if((end_verified&&idle_count==CLOCK_HZ*12-1)||(!end_verified&&idle_count==CLOCK_HZ-1))begin
                fast<=0;guard_count<=0;rate_ready<=1;flush<=1;fault<=1;idle_count<=0;
            end else idle_count<=idle_count+1'b1;
        end
    end
endmodule
