// Core-specific adapter. A descriptor remains held until done toggles back.
// Writes wait for SDRAM acknowledgement plus recovery cycles. END reads every
// ROM word back and checks CRC(header || actual SDRAM bytes) before START.
module tc_snes_rom_sink #(
    parameter integer CLOCK_HZ=21484000,
    parameter integer MAX_ROM_BYTES=8257536
)(
    input logic clk,resetn,
    input logic req,input logic [7:0] req_op,
    input logic [31:0] req_offset,req_total,req_digest,
    input logic [10:0] req_count,input logic req_bank,
    output logic done=0,ok=0,
    output logic [4:0] display_status=1,
    output logic block_bank=0,output logic [9:0] block_address=0,input logic [7:0] block_data,
    output logic header_reset=0,header_valid=0,output logic [7:0] header_data=0,
    output logic bus_owner=0,bus_req=0,bus_we=0,
    output logic [21:0] bus_address=0,output logic [15:0] bus_data=0,
    input logic bus_ack,input logic [15:0] bus_read_data
);
    localparam [3:0] IDLE=0,BEGIN_WAIT=1,FETCH=2,FETCH_WAIT=3,CONSUME=4,
        WRITE_ACK=5,WRITE_DRAIN=6,READ_ISSUE=7,READ_ACK=8,READ_DRAIN=9,COMPLETE=10,DISPATCH=11;
    logic [3:0] state=IDLE;
    logic [1:0] req_sync=0 /* synthesis syn_preserve=1 */;
    logic [1:0] ack_sync=0 /* synthesis syn_preserve=1 */;
    logic request_seen=0;
    logic [7:0] op_hold=0;
    logic [31:0] offset_hold=0,requested_total=0;
    logic [31:0] total_hold=0,digest_hold=0,written=0,read_bytes=0;
    logic [10:0] count_hold=0,index=0;
    logic [7:0] low_byte=0;
    logic low_valid=0,verified=0,poisoned=0,block_last=0;
    logic [31:0] header_crc=32'hffffffff,read_crc=32'hffffffff;
    logic [31:0] timeout_count=0;
    logic [2:0] settle=0;
    function automatic [31:0] crc_byte(input [31:0] initial_crc,input [7:0] value);
        reg [31:0] c;
        begin c=initial_crc^{24'b0,value};for(integer b=0;b<8;b=b+1)c=(c>>1)^(c[0]?32'hedb88320:0);crc_byte=c;end
    endfunction
    // Display only. Observe committed DATA; none of these registers drive the bus.
    logic [27:0] scaled_bytes=0, next_mark=0;
    logic [23:0] body_size=0;
    wire [23:0] committed_body = written[23:0]-24'd64;
    always_ff @(posedge clk) begin
        if(!resetn) begin
            display_status<=1; scaled_bytes<=0; next_mark<=0; body_size<=0;
        end else if(state==DISPATCH && op_hold==1) begin
            display_status<=2; scaled_bytes<=0;
            body_size<=requested_total[23:0]-24'd64;
            next_mark<=requested_total[23:0]-24'd64;
        end else if(state==DISPATCH && op_hold==3) display_status<=23;
        else if(state==COMPLETE && ok && op_hold==4) display_status<=0;
        else if(state==COMPLETE && ok && op_hold==2 && written>=64)
            scaled_bytes<=({4'b0,committed_body}<<4)+({4'b0,committed_body}<<2);
        else if(display_status>=2 && display_status<22 && scaled_bytes>=next_mark) begin
            display_status<=display_status+1'b1;
            next_mark<=next_mark+body_size;
        end
    end
    wire [31:0] checked_crc=crc_byte(crc_byte(read_crc,bus_read_data[7:0]),bus_read_data[15:8]);
    always_ff @(posedge clk)begin
        req_sync<={req_sync[0],req};ack_sync<={ack_sync[0],bus_ack};
        header_reset<=0;header_valid<=0;
        if(!resetn)begin
            state<=IDLE;req_sync<=0;ack_sync<=0;done<=0;ok<=0;request_seen<=0;
            bus_owner<=0;bus_req<=0;bus_we<=0;bus_address<=0;bus_data<=0;
            written<=0;low_valid<=0;verified<=0;poisoned<=0;timeout_count<=0;
            header_crc<=32'hffffffff;
        end else begin
            if(state==WRITE_ACK||state==READ_ACK)begin
                if(timeout_count==CLOCK_HZ/100-1)begin ok<=0;poisoned<=1;verified<=0;state<=COMPLETE;end
                else timeout_count<=timeout_count+1'b1;
            end else timeout_count<=0;
            case(state)
                IDLE:if(req_sync[1]!=done)begin
                    // The source holds all fields through the returned ack.
                    // Capture after two sync stages, then dispatch one cycle later.
                    request_seen<=req_sync[1];op_hold<=req_op;offset_hold<=req_offset;
                    requested_total<=req_total;digest_hold<=req_digest;count_hold<=req_count;block_bank<=req_bank;
                    ok<=0;state<=DISPATCH;
                end
                DISPATCH:begin
                    if(op_hold==1)begin
                        if(poisoned||requested_total<66||requested_total>MAX_ROM_BYTES+64||requested_total[0])state<=COMPLETE;
                        else begin
                            total_hold<=requested_total;written<=0;header_crc<=32'hffffffff;
                            low_valid<=0;verified<=0;header_reset<=1;
                            bus_req<=ack_sync[1];bus_owner<=1;bus_we<=0;settle<=4;state<=BEGIN_WAIT;
                        end
                    end else if(op_hold==2)begin
                        if(poisoned||!bus_owner||verified||offset_hold!=written||count_hold==0||count_hold>1024||
                           count_hold>total_hold-written)state<=COMPLETE;
                        else begin index<=0;block_address<=0;state<=FETCH;end
                    end else if(op_hold==3)begin
                        if(poisoned||written!=total_hold||low_valid||written<66)state<=COMPLETE;
                        else begin read_crc<=header_crc;read_bytes<=0;bus_address<=0;state<=READ_ISSUE;end
                    end else if(op_hold==4)begin
                        if(verified&&!poisoned)begin bus_owner<=0;ok<=1;end
                        state<=COMPLETE;
                    end else state<=COMPLETE;
                end
                BEGIN_WAIT:if(settle==0)begin ok<=1;state<=COMPLETE;end else settle<=settle-1'b1;
                FETCH:state<=FETCH_WAIT;
                FETCH_WAIT:state<=CONSUME;
                CONSUME:begin
                    written<=written+1'b1;index<=index+1'b1;block_address<=index[9:0]+1'b1;
                    block_last<=index+1==count_hold;
                    if(written<64)begin
                        header_data<=block_data;header_valid<=1;header_crc<=crc_byte(header_crc,block_data);
                        if(index+1==count_hold)begin settle<=2;state<=WRITE_DRAIN;end else state<=FETCH;
                    end else if(!low_valid)begin
                        low_byte<=block_data;low_valid<=1;
                        if(index+1==count_hold)begin settle<=2;state<=WRITE_DRAIN;end else state<=FETCH;
                    end else begin
                        low_valid<=0;bus_address<=(written-64)>>1;bus_data<={block_data,low_byte};bus_we<=1;
                        bus_req<=~bus_req;state<=WRITE_ACK;timeout_count<=0;
                    end
                end
                WRITE_ACK:if(ack_sync[1]==bus_req)begin settle<=4;state<=WRITE_DRAIN;end
                WRITE_DRAIN:if(settle!=0)settle<=settle-1'b1;
                    else if(block_last)begin ok<=1;state<=COMPLETE;end else state<=FETCH;
                READ_ISSUE:begin bus_we<=0;bus_req<=~bus_req;state<=READ_ACK;timeout_count<=0;end
                READ_ACK:if(ack_sync[1]==bus_req)begin settle<=4;state<=READ_DRAIN;end
                READ_DRAIN:if(settle!=0)settle<=settle-1'b1;
                    else begin
                        read_crc<=checked_crc;read_bytes<=read_bytes+2;
                        if(read_bytes+2==total_hold-64)begin
                            verified<=(checked_crc^32'hffffffff)==digest_hold;
                            ok<=(checked_crc^32'hffffffff)==digest_hold;state<=COMPLETE;
                        end else begin bus_address<=bus_address+1'b1;state<=READ_ISSUE;end
                    end
                COMPLETE:begin done<=request_seen;state<=IDLE;end
                default:begin poisoned<=1;ok<=0;state<=COMPLETE;end
            endcase
        end
    end
endmodule
