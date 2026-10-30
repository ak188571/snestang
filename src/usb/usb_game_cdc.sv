// Acknowledged mailbox for an atomic, slow-changing game state.
// src_hold cannot change while a destination capture is outstanding.
// Intermediate source states may coalesce while busy; the latest state is sent next.
// A periodic refresh also republishes state after an independent destination reset.
module usb_game_cdc #(
    parameter integer WIDTH = 12,
    parameter integer REFRESH_CLOCKS = 12000
) (
    input logic src_clk, src_resetn, src_valid,
    input logic [WIDTH-1:0] src_data,
    input logic dst_clk, dst_resetn,
    output logic [WIDTH-1:0] dst_data = '0,
    output logic dst_valid = 0
);
    logic [WIDTH-1:0] src_hold = '0 /* synthesis syn_preserve=1 */;
    logic src_toggle = 0 /* synthesis syn_preserve=1 */;
    logic [1:0] ack_sync = 0 /* synthesis syn_preserve=1 */;
    logic [1:0] toggle_sync = 0 /* synthesis syn_preserve=1 */;
    logic toggle_seen = 0;
    integer refresh_count = 0;
    always_ff @(posedge src_clk) begin
        if (!src_resetn) begin
            src_hold <= '0;
            src_toggle <= 0;
            ack_sync <= 0;
            refresh_count <= 0;
        end else begin
            ack_sync <= {ack_sync[0],toggle_seen};
            if (refresh_count < REFRESH_CLOCKS-1) refresh_count <= refresh_count+1;
            if (src_toggle == ack_sync[1] &&
                (src_valid || src_data != src_hold || refresh_count == REFRESH_CLOCKS-1)) begin
                src_hold <= src_data;
                src_toggle <= ~src_toggle;
                refresh_count <= 0;
            end
        end
    end
    always_ff @(posedge dst_clk) begin
        dst_valid <= 0;
        if (!dst_resetn) begin
            toggle_sync <= 0;
            toggle_seen <= 0;
            dst_data <= '0;
        end else begin
            toggle_sync <= {toggle_sync[0],src_toggle};
            if (toggle_sync[1] != toggle_seen) begin
                dst_data <= src_hold;
                toggle_seen <= toggle_sync[1];
                dst_valid <= 1;
            end
        end
    end
endmodule

// PLL lock and USER button assert reset asynchronously, release on clk12.
module usb_reset_sync (
    input logic clk, async_resetn,
    output wire resetn
);
    logic [1:0] reset_pipe = 0 /* synthesis syn_preserve=1 */;
    always_ff @(posedge clk or negedge async_resetn) begin
        if (!async_resetn) reset_pipe <= 0;
        else reset_pipe <= {reset_pipe[0],1'b1};
    end
    assign resetn = reset_pipe[1];
endmodule
