// Stage1 insertion point: no effects, registers, buffers, or timing changes.
// The frame-applied configuration is transported separately by tc_crt_config.
module tc_crt_bypass (
    input wire [23:0] rgb_in,
    output wire [23:0] rgb_out
);
    assign rgb_out=rgb_in;
endmodule
