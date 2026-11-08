// Uses the production Console138K controller, with a command-level SDRAM model.
// fclk:mclk is 3:1. The model does not validate analogue SDRAM timing.
module tb_sink_controller(
    input logic fclk,mclk,resetn,req,
    input logic [7:0] op,
    input logic [31:0] offset,total,digest,
    input logic [10:0] count,
    input logic corrupt_read,
    input logic [3:0] ack_delay,
    output wire done,ok,busy,owner,header_finished,
    output wire [7:0] rom_type,
    output wire [3:0] rom_size,ram_size,
    output wire [3:0] sink_state,
    output logic [31:0] writes=0,reads=0,headers=0,refreshes=0
);
    wire [9:0] address;
    logic [7:0] data=0;
    // Same synchronous byte-RAM latency as the production executor.
    function automatic [7:0] source_byte(input [31:0] at);
        source_byte=8'((at*32'd73)^(at>>8)^32'h5a);
    endfunction
    always @(posedge mclk) data<=source_byte(offset+{22'b0,address});
    wire breq,bwe,back,controller_ack,hreset,hvalid;
    wire [7:0] hdata;
    logic [14:0] delayed_ack=0;
    always @(posedge mclk)if(!resetn)delayed_ack<=0;else delayed_ack<={delayed_ack[13:0],controller_ack};
    assign back=ack_delay==0?controller_ack:delayed_ack[ack_delay-1'b1];
    wire [21:0] baddr;
    wire [15:0] bdata,brdata;
`ifdef BASELINE
    tc_snes_rom_sink_baseline sink(
`else
    tc_snes_rom_sink sink(
`endif
        .clk(mclk),.resetn(resetn),.req(req),.req_op(op),.req_offset(offset),
        .req_total(total),.req_digest(digest),.req_count(count),.req_bank(2'b0),
        .done(done),.ok(ok),.display_status(),.block_bank(),.block_address(address),.block_data(data),
        .header_reset(hreset),.header_valid(hvalid),.header_data(hdata),
        .bus_owner(owner),.bus_req(breq),.bus_we(bwe),.bus_address(baddr),.bus_data(bdata),
        .bus_ack(back),.bus_read_data(brdata));
    assign sink_state=sink.state;
    smc_parser parser(.clk(mclk),.resetn(resetn&&!hreset),.rom_d(hdata),.rom_strb(hvalid),
        .rom_type(rom_type),.rom_mask(),.ram_mask(),.rom_size(rom_size),.ram_size(ram_size),.header_finished(header_finished));
    logic clkref=0;
    always @(posedge mclk) if(!resetn)clkref<=0;else clkref<=~clkref;
    wire [15:0] dq;
    wire [12:0] a;
    wire [1:0] ba,dqm;
    wire cs,ras,cas,we;
    sdram_snes controller(.clk(fclk),.mclk(mclk),.clkref(clkref),.resetn(resetn),.busy(busy),
        .SDRAM_DQ(dq),.SDRAM_A(a),.SDRAM_BA(ba),.SDRAM_DQM(dqm),
        .SDRAM_nCS(cs),.SDRAM_nRAS(ras),.SDRAM_nCAS(cas),.SDRAM_nWE(we),.SDRAM_CKE(),
        .cpu_din(bdata),.cpu_port(1'b0),.cpu_port0(brdata),.cpu_port1(),.cpu_addr(baddr),
        .cpu_req(breq),.cpu_req_ack(controller_ack),.cpu_we(bwe),.cpu_ds(2'b11),
        .bsram_addr(20'b0),.bsram_din(8'b0),.bsram_dout(),.bsram_req(1'b0),.bsram_req_ack(),.bsram_we(1'b0),
        .aram_16(1'b0),.aram_addr(16'b0),.aram_din(16'b0),.aram_dout(),.aram_req(1'b0),.aram_req_ack(),.aram_we(1'b0),
        .rv_addr(22'b0),.rv_din(16'b0),.rv_ds(2'b0),.rv_dout(),.rv_req(1'b0),.rv_req_ack(),.rv_we(1'b0),.total_refresh());
    logic [15:0] memory[0:4194303];
    logic [12:0] row[0:3];
    logic [15:0] read_value=0;
    logic [2:0] read_delay=7;
    wire [21:0] word_address={row[ba],a[8:0]};
    assign dq=read_delay==0?read_value:16'bz;
    always @(negedge fclk)begin
        if(!resetn)begin writes<=0;reads<=0;refreshes<=0;read_delay<=7;end
        else begin
            if(read_delay<7)read_delay<=read_delay==0?3'd7:read_delay-1'b1;
            case({cs,ras,cas,we})
                4'b0011:row[ba]<=a;
                4'b0100:begin
                    assert(ba==0 && dqm==0);
                    assert(word_address==writes[21:0]);
                    assert(dq=={source_byte(65+{9'b0,word_address,1'b0}),source_byte(64+{9'b0,word_address,1'b0})});
                    memory[word_address]<=dq;writes<=writes+1'b1;
                end
                4'b0101:begin
                    assert(ba==0);read_value<=memory[word_address]^((corrupt_read&&word_address==3)?16'h100:16'b0);
                    read_delay<=2;reads<=reads+1'b1;
                end
                4'b0001:refreshes<=refreshes+1'b1;
                default:;
            endcase
        end
    end
    always @(posedge mclk)if(!resetn||hreset)headers<=0;else if(hvalid)headers<=headers+1'b1;
endmodule
