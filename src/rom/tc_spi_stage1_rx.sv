// MODE1 receiver in the SPI input sampling clock domain.
module tc_spi_stage1_rx (
    input wire clk, cs_n, sck, mosi,
    output reg byte_valid = 0, output wire [7:0] observed_byte
);
    reg [2:0] sck_sync = 0;
    reg [1:0] cs_sync = 3, data_sync = 0;
    reg [2:0] count = 0;
    reg [6:0] shift = 0;
    reg [7:0] last_byte /* synthesis syn_preserve=1 */ = 0;
    assign observed_byte = last_byte;
    always @(posedge clk) begin
        byte_valid <= 0;
        cs_sync <= {cs_sync[0], cs_n};
        sck_sync <= {sck_sync[1:0], sck};
        data_sync <= {data_sync[0], mosi};
        if (cs_sync[1]) begin
            count <= 0;
        end else if (sck_sync[2:1] == 2'b10) begin
            shift <= {shift[5:0], data_sync[1]};
            count <= count + 1'b1;
            if (count == 7) begin
                last_byte <= {shift, data_sync[1]};
                byte_valid <= 1;
            end
        end
    end
endmodule

// A received byte arrives at most once per 250 ns at 32 MHz. Hold it until
// the 80 MHz consumer acknowledges capture. An overrun poisons the session.
module tc_spi_clock_crossing (
    input logic sample_clk,sample_resetn,clk,resetn,owned,cs_n,sck,mosi,
    output logic [7:0] byte_data=0,
    output logic byte_valid=0,
    output wire overflow
);
    logic [1:0] owner_sync=0,ack_sync=0 /* synthesis syn_preserve=1 */;
    logic [1:0] req_sync=0,overrun_sync=0 /* synthesis syn_preserve=1 */;
    logic request=0,ack=0,overrun=0;
    logic [7:0] source_data=0;
    wire sampled_valid;
    wire [7:0] sampled_byte;

    tc_spi_stage1_rx sampler(.clk(sample_clk),.cs_n(cs_n || !owner_sync[1]),
        .sck(sck),.mosi(mosi),.byte_valid(sampled_valid),.observed_byte(sampled_byte));

    always_ff @(posedge sample_clk) begin
        owner_sync<={owner_sync[0],owned};
        ack_sync<={ack_sync[0],ack};
        if (!sample_resetn) begin
            owner_sync<=0;
            ack_sync<=0;
            request<=0;
            overrun<=0;
        end else begin
            if (!owner_sync[1]) overrun<=0;
            else if (sampled_valid) begin
                if (ack_sync[1]!=request) overrun<=1;
                else begin
                    source_data<=sampled_byte;
                    request<=~request;
                end
            end
        end
    end

    assign overflow=overrun_sync[1];
    always_ff @(posedge clk) begin
        req_sync<={req_sync[0],request};
        overrun_sync<={overrun_sync[0],overrun};
        byte_valid<=0;
        if (!resetn) begin
            req_sync<=0;
            overrun_sync<=0;
            ack<=0;
        end else if (req_sync[1]!=ack) begin
            byte_data<=source_data;
            byte_valid<=1;
            ack<=req_sync[1];
        end
    end
endmodule
