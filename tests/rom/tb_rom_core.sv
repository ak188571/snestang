module tb_rom_core #(parameter bit LINK_CONTROL=1)(
    input logic clk,mem_clk,resetn,fault,
    input logic [7:0] rx_data,input logic rx_valid,
    output wire [7:0] tx_data,output wire tx_valid,
    input logic tx_ready,link_at_base,stall_memory,corrupt_read,
    output wire [4:0] display_status,output wire held,owned,output wire [31:0] writes,headers,
    output wire [15:0] first_word
);
    wire [1:0] bank,rd_bank;
    wire req,done,ok,bus_owner,breq,bwe,hreset,hvalid;
    wire [7:0] operation,mem_data,hdata;
    wire [31:0] offset,total,digest;
    wire [10:0] count;
    wire [9:0] address;
    wire [21:0] baddr;
    wire [15:0] bdata;
    logic back=0;logic [15:0] brdata=0;
    tc_rom_receiver #(.LINK_CONTROL(LINK_CONTROL)) engine(.clk(clk),.resetn(resetn),.transport_fault(fault),.rx_data(rx_data),.rx_valid(rx_valid),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.tx_idle(1'b1),.link_at_base(link_at_base),.link_available(1'b1),
        .rate_pulse(),.rate_value(),.owned(owned),.hold_reset(held),.processing(),.activity(),
        .sink_req(req),.sink_op(operation),.sink_offset(offset),.sink_total(total),.sink_digest(digest),.sink_count(count),.sink_bank(bank),
        .sink_done(done),.sink_ok(ok),.mem_clk(mem_clk),.mem_bank(rd_bank),.mem_address(address),.mem_data(mem_data));
    tc_snes_rom_sink sink(.clk(mem_clk),.resetn(resetn),.req(req),.req_op(operation),.req_offset(offset),.req_total(total),
        .req_digest(digest),.req_count(count),.req_bank(bank),.display_status(display_status),.done(done),.ok(ok),.block_bank(rd_bank),.block_address(address),.block_data(mem_data),
        .header_reset(hreset),.header_valid(hvalid),.header_data(hdata),.bus_owner(bus_owner),.bus_req(breq),.bus_we(bwe),
        .bus_address(baddr),.bus_data(bdata),.bus_ack(back),.bus_read_data(brdata));
    logic [15:0] memory[0:4194303];
    logic [31:0] write_count=0,header_count=0;
    assign writes=write_count;assign headers=header_count;assign first_word=memory[0];
    logic pending=0,latched_req=0,latched_we=0;
    logic [21:0] latched_address=0;
    logic [15:0] latched_data=0;
    logic [2:0] wait_count=0;
    always_ff @(posedge mem_clk)begin
        if(!resetn)begin back<=0;pending<=0;write_count<=0;header_count<=0;end
        else begin
            if(hreset)header_count<=0;else if(hvalid)header_count<=header_count+1'b1;
            if(!stall_memory)begin
                if(!pending&&breq!=back)begin
                    pending<=1;latched_req<=breq;latched_we<=bwe;latched_address<=baddr;latched_data<=bdata;wait_count<=4;
                end else if(pending)begin
                    if(wait_count==2)begin
                        back<=latched_req;
                        if(latched_we)begin memory[latched_address]<=latched_data;write_count<=write_count+1'b1;end
                    end
                    if(wait_count==0)begin
                        if(!latched_we)brdata<=memory[latched_address]^((corrupt_read&&latched_address==3)?16'h100:16'h0);
                        pending<=0;
                    end else wait_count<=wait_count-1'b1;
                end
            end
        end
    end
endmodule
