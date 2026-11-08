// Transport-independent ingress and transaction engine. Capture the next
// request while the previous CRC-checked block is being committed to SDRAM.
module tc_rom_receiver #(
    parameter integer CLOCK_HZ=96000000,
    parameter integer MAX_TOTAL=8388672,
    parameter bit LINK_CONTROL=1
)(
    input logic clk,resetn,transport_fault,
    input logic [7:0] rx_data,input logic rx_valid,
    output logic [7:0] tx_data,output wire tx_valid,input logic tx_ready,tx_idle,
    input logic link_at_base,link_available,
    output logic rate_pulse,output logic [31:0] rate_value,
    output wire owned,hold_reset,processing,end_verified,
    output logic activity,
    // A held descriptor and acknowledged toggle cross to the core adapter.
    output wire sink_req,
    output wire [7:0] sink_op,
    output wire [31:0] sink_offset,sink_total,sink_digest,
    output wire [10:0] sink_count,
    output wire [1:0] sink_bank,
    input logic sink_done,sink_ok,
    input logic mem_clk,input logic [1:0] mem_bank,input logic [9:0] mem_address,
    output wire [7:0] mem_data
);

    // Two in-flight 1048-byte DATA requests fit even while the executor waits
    // for SDRAM. Overflow poisons the session; no byte is silently dropped.
    logic [7:0] fifo[0:4095];
    logic [11:0] wr=0,rd=0;
    logic [12:0] used=0;
    logic [7:0] queued_byte=0;
    logic pending=0,cooldown=0,overflow=0;
    wire ready,engine_owned,engine_activity;
    wire take=ready&&!pending&&!cooldown&&used!=0;
    wire full=used==4096;
    wire fault=transport_fault||overflow;
    wire consume=pending&&ready;
    // Unrelated legacy bytes also pass this ingress. Queue occupancy must not
    // pause the legacy parser before a valid ROM transaction claims the link.
    assign owned=engine_owned;
    always_ff @(posedge clk)begin
        if(rx_valid&&!full)fifo[wr]<=rx_data;
        if(take)queued_byte<=fifo[rd];
        if(!resetn||fault)begin wr<=0;rd<=0;used<=0;pending<=0;cooldown<=0;overflow<=0;end
        else begin
            cooldown<=consume;
            if(rx_valid&&full)overflow<=1;
            if(rx_valid&&!full)wr<=wr+1'b1;
            if(take)begin rd<=rd+1'b1;pending<=1;end
            if(consume)pending<=0;
            case({rx_valid&&!full,take})
                2'b10:used<=used+1'b1;
                2'b01:used<=used-1'b1;
                default:;
            endcase
        end
    end
    assign activity=engine_activity||rx_valid;
    tc_rom_executor #(.CLOCK_HZ(CLOCK_HZ),.MAX_TOTAL(MAX_TOTAL),.LINK_CONTROL(LINK_CONTROL)) executor(
        .clk(clk),.resetn(resetn),.transport_fault(fault),.rx_data(queued_byte),.rx_valid(consume),
        .rx_ready(ready),.tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.tx_idle(tx_idle),
        .link_at_base(link_at_base),.link_available(link_available),.rate_pulse(rate_pulse),.rate_value(rate_value),
        .owned(engine_owned),.hold_reset(hold_reset),.processing(processing),.end_verified(end_verified),.activity(engine_activity),
        .sink_req(sink_req),.sink_op(sink_op),.sink_offset(sink_offset),.sink_total(sink_total),.sink_digest(sink_digest),
        .sink_count(sink_count),.sink_bank(sink_bank),.sink_done(sink_done),.sink_ok(sink_ok),
        .mem_clk(mem_clk),.mem_bank(mem_bank),.mem_address(mem_address),.mem_data(mem_data));
endmodule

// ROMXFR1 byte-stream transaction engine. No UART pins, DMA or SPI timing.
// Three banks retain the last two committed DATA blocks and one candidate.
module tc_rom_executor #(
    parameter integer CLOCK_HZ=96000000,
    parameter integer MAX_TOTAL=8388672,
    parameter bit LINK_CONTROL=1
)(
    input logic clk,resetn,transport_fault,
    input logic [7:0] rx_data,input logic rx_valid,output wire rx_ready,
    output logic [7:0] tx_data,output wire tx_valid,input logic tx_ready,tx_idle,
    input logic link_at_base,link_available,
    output logic rate_pulse,output logic [31:0] rate_value,
    output wire owned,hold_reset,processing,end_verified,
    output logic activity,
    // A held descriptor and acknowledged toggle cross to the core adapter.
    output logic sink_req=0,
    output logic [7:0] sink_op=0,
    output logic [31:0] sink_offset=0,sink_total=0,sink_digest=0,
    output logic [10:0] sink_count=0,
    output logic [1:0] sink_bank=0,
    input logic sink_done,sink_ok,
    input logic mem_clk,input logic [1:0] mem_bank,input logic [9:0] mem_address,
    output wire [7:0] mem_data
);
    localparam [7:0] BEGIN_OP=1,DATA_OP=2,END_OP=3,START_OP=4,ABORT_OP=5,WINDOW_OP=6,RATE_OP=16,SYNC_OP=17;
    localparam [7:0] OK=0,FORMAT=1,SESSION=2,ORDER=3,RANGE=4,STATE=5,INTEGRITY=7,BACKEND=8;
    localparam [2:0] IDLE=0,RECEIVING=1,VERIFIED=2,RUNNING=3,ABORTED=4;
    localparam [2:0] RECEIVE=0,EXECUTE=1,REPLYING=2,DRAIN=3,VALIDATE=4;
    logic [2:0] session_state=IDLE;
    logic [2:0] mode=RECEIVE;
    logic [31:0] remaining=0;
    logic [31:0] session_id=0,total=0,next_offset=0,next_sequence=0,stream_crc=32'hffffffff;
    logic link_confirmed=1;
    logic backend_poisoned=0;
    logic [1:0] done_sync=0 /* synthesis syn_preserve=1 */;
    logic ok_sync0=0,ok_sync1=0;
    logic [31:0] exec_timer=0;
    logic [31:0] frame_crc=32'hffffffff,received_crc=0,candidate_crc=32'hffffffff;
    logic [11:0] position=0,frame_length=0,skip_left=0;
    logic [11:0] last_position=0;
    logic reading_crc=0,payload_active=0;
    logic [10:0] payload_left=0;
    logic [7:0] command=0,version=0,op=0;
    logic [31:0] rid=0,req_sequence=0,offset=0,arg=0;
    // The request sequence is stable from the header through the sink ACK.
    // Prepare the successor in four independent byte lanes before committing it.
    wire [31:0] sequence_successor;
    for (genvar lane=0; lane<4; lane=lane+1) begin: sequence_lanes
        reg carry;
        if (lane==0) always_comb carry=1'b1;
        else always_ff @(posedge clk) carry<=&req_sequence[lane*8-1:0];
        reg [7:0] same_byte, incremented_byte;
        always_ff @(posedge clk) begin
            same_byte<=req_sequence[lane*8+:8];
            incremented_byte<=req_sequence[lane*8+:8]+1'b1;
        end
        assign sequence_successor[lane*8+:8]=carry?incremented_byte:same_byte;
    end
    logic [15:0] count=0;
    logic [31:0] byte_timer=0;
    // Wide comparisons settle while the four CRC bytes arrive (at least
    // eight clocks). Command/descriptor enables use these registered results.
    logic same_session=0,ordered_request=0,begin_format_ok=0,begin_total_ok=0;
    logic same_total=0,duplicate_ok=0,data_range_ok=0,end_digest_ok=0,stream_complete=0;
    logic empty_body=0,control_body=0,at_start=0,rate_base=0,rate_supported=0;
    always_ff @(posedge clk)begin
        same_session<=rid==session_id;
        ordered_request<=req_sequence==next_sequence&&offset==next_offset;
        begin_format_ok<=count==4&&req_sequence==0&&offset==0;
        begin_total_ok<=arg!=0&&arg<=MAX_TOTAL;
        same_total<=arg==total;
        duplicate_ok<=last_valid&&req_sequence==last_sequence&&offset==last_offset&&count==last_count&&same_last;
        data_range_ok<=count!=0&&{16'b0,count}<=remaining;
        end_digest_ok<=(stream_crc^32'hffffffff)==arg;
        stream_complete<=next_offset==total;
        empty_body<=count==0;control_body<=count==4;at_start<=next_offset==0;
        rate_base<=arg==2000000;rate_supported<=arg==2000000||arg==8000000;
    end

    logic [1:0] incoming_bank=0,last_bank=1,prev_bank=2;
    logic last_valid=0,same_last=1,prev_valid=0,same_prev=1;
    logic [31:0] prev_sequence=0,prev_offset=0;
    logic [15:0] prev_count=0;
    logic previous_ok=0;
    always_ff @(posedge clk) previous_ok<=prev_valid&&req_sequence==prev_sequence&&offset==prev_offset&&count==prev_count&&same_prev;
    logic [31:0] last_sequence=0,last_offset=0;
    logic [15:0] last_count=0;
    logic [7:0] ram0[0:1023],ram1[0:1023],ram2[0:1023];
    logic [7:0] fast0,fast1,fast2,slow0,slow1,slow2;
    wire [9:0] payload_address=position>=20?position-20:0;
    wire store=mode==RECEIVE && rx_valid && !skip_left && command==8'h30 && position>=20 && position<20+count && count<=1024;
    always_ff @(posedge clk)begin
        // GW5AST DPB supports write-through/no-change, not read-before-write.
        // The bank being written is never the duplicate-comparison bank.
        if(store&&incoming_bank==0)begin ram0[payload_address]<=rx_data;fast0<=rx_data;end
        else fast0<=ram0[payload_address];
        if(store&&incoming_bank==1)begin ram1[payload_address]<=rx_data;fast1<=rx_data;end
        else fast1<=ram1[payload_address];
        if(store&&incoming_bank==2)begin ram2[payload_address]<=rx_data;fast2<=rx_data;end
        else fast2<=ram2[payload_address];
    end
    always_ff @(posedge mem_clk)begin slow0<=ram0[mem_address];slow1<=ram1[mem_address];slow2<=ram2[mem_address];end
    assign mem_data=mem_bank==2?slow2:mem_bank==1?slow1:slow0;
    assign rx_ready=mode==RECEIVE;
    function automatic [31:0] crc_byte(input [31:0] initial_crc,input [7:0] value);
        reg [31:0] c;
        begin c=initial_crc^value;for(integer bitno=0;bitno<8;bitno=bitno+1)c=(c>>1)^((c&1)?32'hedb88320:0);crc_byte=c;end
    endfunction
    logic [7:0] reply_status=0,reply_op=0;
    logic [31:0] reply_id=0,reply_sequence=0,reply_offset=0,reply_crc=32'hffffffff;
    logic [4:0] reply_index=0;
    logic rate_pending=0;
    logic [31:0] pending_rate=2000000;
    task automatic reply(input [7:0] status,input [31:0] at);
        begin
            reply_status<=status;reply_op<=op;reply_id<=rid;reply_sequence<=req_sequence;reply_offset<=at;
            reply_index<=0;reply_crc<=32'hffffffff;mode<=REPLYING;
        end
    endtask
    task automatic execute_sink(input [7:0] operation);
        begin
            sink_op<=operation;sink_offset<=offset;sink_count<=count[10:0];sink_total<=total;
            sink_digest<=arg;sink_bank<=incoming_bank;sink_req<=~sink_req;mode<=EXECUTE;exec_timer<=0;
        end
    endtask
    assign tx_valid=mode==REPLYING;
    assign processing=mode==EXECUTE;
    // Allows a UART adapter to keep its idle watchdog longer than the host's
    // END timeout, so a lost END ACK can be retried after that full timeout.
    assign end_verified=session_state==VERIFIED;
    assign hold_reset=session_state==RECEIVING||session_state==VERIFIED||session_state==ABORTED;
    assign owned=hold_reset||mode!=RECEIVE;
    always_comb begin
        tx_data=0;
        case(reply_index)
            0:tx_data=8'haa;1:tx_data=0;2:tx_data=22;3:tx_data=8'h31;4:tx_data=1;5:tx_data=reply_op;
            6,7,8,9:tx_data=reply_id>>((9-reply_index)*8);
            10,11,12,13:tx_data=reply_sequence>>((13-reply_index)*8);
            14,15,16,17:tx_data=reply_offset>>((17-reply_index)*8);
            18:tx_data=0;19:tx_data=1;20:tx_data=reply_status;
            21,22,23,24:tx_data=(reply_crc^32'hffffffff)>>((24-reply_index)*8);
            default:tx_data=0;
        endcase
    end
    always_ff @(posedge clk)begin
        done_sync<={done_sync[0],sink_done};ok_sync0<=sink_ok;ok_sync1<=ok_sync0;
        rate_pulse<=0;activity<=0;
        if(!resetn)begin
            mode<=RECEIVE;session_state<=IDLE;session_id<=0;next_offset<=0;next_sequence<=0;remaining<=0;
            position<=0;skip_left<=0;byte_timer<=0;sink_req<=0;done_sync<=0;
            reading_crc<=0;payload_active<=0;payload_left<=0;
            stream_crc<=32'hffffffff;last_valid<=0;prev_valid<=0;incoming_bank<=0;last_bank<=1;prev_bank<=2;
            rate_pending<=0;link_confirmed<=1;exec_timer<=0;backend_poisoned<=0;
        end else if(transport_fault)begin
            if(mode==EXECUTE)backend_poisoned<=1;
            mode<=RECEIVE;position<=0;skip_left<=0;rate_pending<=0;link_confirmed<=0;
            reading_crc<=0;payload_active<=0;
            if(session_state!=IDLE&&session_state!=RUNNING)session_state<=ABORTED;
        end else begin
            // Explicit CRC phase avoids a length subtract/position compare on
            // every received-CRC register enable. Fields remain registered.
            if(mode==RECEIVE&&rx_valid)begin
                if(reading_crc)received_crc<={received_crc[23:0],rx_data};
                if(payload_active)begin
                    payload_left<=payload_left-1'b1;
                    if(payload_left==1)begin payload_active<=0;reading_crc<=1;end
                end
            end
            // Decode only a previously CRC-validated, fully registered frame.
            // No CRC/framing cone feeds the command/descriptor enable paths.
            if(mode==VALIDATE)begin
                if(op==BEGIN_OP)begin
                    if(backend_poisoned)reply(BACKEND,next_offset);
                    else if(!begin_format_ok)reply(FORMAT,next_offset);
                    else if(!begin_total_ok)reply(RANGE,next_offset);
                    else if(same_session)begin
                        if(session_state==RECEIVING&&same_total)reply(OK,next_offset);else reply(SESSION,next_offset);
                    end else if(session_state!=IDLE&&session_state!=ABORTED)reply(STATE,next_offset);
                    else begin
                        session_id<=rid;total<=arg;remaining<=arg;next_offset<=0;next_sequence<=0;
                        stream_crc<=32'hffffffff;last_valid<=0;prev_valid<=0;session_state<=RECEIVING;link_confirmed<=1;
                        execute_sink(BEGIN_OP);sink_total<=arg;
                    end
                end else if(!same_session)reply(SESSION,next_offset);
                else if(op==ABORT_OP)begin
                    if(!empty_body||req_sequence!=0||offset!=0)reply(FORMAT,next_offset);
                    else begin session_state<=ABORTED;reply(OK,next_offset);end
                end else if(op==DATA_OP)begin
                    if(session_state!=RECEIVING||!link_confirmed)reply(STATE,next_offset);
                    else if(duplicate_ok||previous_ok)reply(OK,offset+count);
                    else if(!ordered_request)reply(ORDER,next_offset);
                    else if(!data_range_ok)reply(RANGE,next_offset);
                    else execute_sink(DATA_OP);
                end else if(op==WINDOW_OP)begin
                    if(!control_body||!ordered_request)reply(FORMAT,next_offset);
                    else if(session_state!=RECEIVING||!at_start||!link_confirmed)reply(STATE,next_offset);
                    else if(arg!=2)reply(RANGE,next_offset);
                    else reply(OK,next_offset);
                end else if(op==END_OP)begin
                    if(!control_body||!ordered_request)reply(FORMAT,next_offset);
                    else if(!end_digest_ok||!stream_complete)reply(INTEGRITY,next_offset);
                    else if(session_state==VERIFIED||session_state==RUNNING)reply(OK,next_offset);
                    else if(session_state!=RECEIVING)reply(STATE,next_offset);
                    else execute_sink(END_OP);
                end else if(op==START_OP)begin
                    if(!empty_body||!ordered_request)reply(FORMAT,next_offset);
                    else if(session_state==RUNNING)reply(OK,next_offset);
                    else if(session_state!=VERIFIED||!link_at_base||!link_confirmed)reply(STATE,next_offset);
                    else execute_sink(START_OP);
                end else if(op==RATE_OP&&LINK_CONTROL)begin
                    if(!control_body||!ordered_request)reply(FORMAT,next_offset);
                    else if(!((session_state==RECEIVING&&at_start)||(session_state==VERIFIED&&rate_base)))reply(STATE,next_offset);
                    else if(!rate_supported)reply(RANGE,next_offset);
                    else begin pending_rate<=arg;rate_pending<=1;link_confirmed<=0;reply(OK,next_offset);end
                end else if(op==SYNC_OP&&LINK_CONTROL)begin
                    if(!empty_body||!ordered_request)reply(FORMAT,next_offset);
                    else if(!link_available||session_state==ABORTED)reply(STATE,next_offset);
                    else begin link_confirmed<=1;reply(OK,next_offset);end
                end else reply(FORMAT,next_offset);
            end else if(mode==EXECUTE)begin
                exec_timer<=exec_timer+1'b1;
                if(done_sync[1]==sink_req)begin
                    activity<=1;
                    if(!ok_sync1)begin session_state<=ABORTED;reply(BACKEND,next_offset);end
                    else case(sink_op)
                        BEGIN_OP:reply(OK,0);
                        DATA_OP:begin
                            next_offset<=next_offset+count;remaining<=remaining-count;next_sequence<=sequence_successor;stream_crc<=candidate_crc;
                            prev_valid<=last_valid;prev_sequence<=last_sequence;prev_offset<=last_offset;prev_count<=last_count;prev_bank<=last_bank;
                            last_valid<=1;last_sequence<=req_sequence;last_offset<=offset;last_count<=count;
                            last_bank<=incoming_bank;incoming_bank<=prev_bank;
                            reply(OK,next_offset+count);
                        end
                        END_OP:begin session_state<=VERIFIED;reply(OK,next_offset);end
                        START_OP:begin session_state<=RUNNING;reply(OK,next_offset);end
                        default:begin session_state<=ABORTED;reply(BACKEND,next_offset);end
                    endcase
                end else if(exec_timer==CLOCK_HZ*12-1)begin backend_poisoned<=1;session_state<=ABORTED;reply(BACKEND,next_offset);end
            end else if(mode==REPLYING&&tx_ready)begin
                if(reply_index<21)reply_crc<=crc_byte(reply_crc,tx_data);
                if(reply_index==24)mode<=DRAIN;else reply_index<=reply_index+1'b1;
            end else if(mode==DRAIN&&tx_idle)begin
                mode<=RECEIVE;position<=0;skip_left<=0;
                if(rate_pending)begin rate_pulse<=1;rate_value<=pending_rate;rate_pending<=0;end
            end
            if(mode==RECEIVE)begin
                if(position!=0||skip_left!=0)begin
                    if(rx_valid)byte_timer<=0;
                    else if(byte_timer==CLOCK_HZ/1000-1)begin position<=0;skip_left<=0;byte_timer<=0;reading_crc<=0;payload_active<=0;end
                    else byte_timer<=byte_timer+1'b1;
                end
                if(rx_valid)begin
                    if(skip_left!=0)begin skip_left<=skip_left-1'b1;if(skip_left==1)position<=0;end
                    else if(position==0)begin
                        if(rx_data==8'haa)begin
                            position<=1;frame_crc<=crc_byte(32'hffffffff,rx_data);same_last<=1;same_prev<=1;arg<=0;received_crc<=0;
                            reading_crc<=0;payload_active<=0;
                        end
                    end else begin
                        position<=position+1'b1;
                        if(position==1)begin
                            frame_length<={rx_data[3:0],8'b0};frame_crc<=crc_byte(frame_crc,rx_data);
                            if(rx_data>=8)position<=0;
                        end
                        else if(position==2)begin
                            frame_length[7:0]<=rx_data;frame_crc<=crc_byte(frame_crc,rx_data);
                            last_position<={frame_length[11:8],rx_data}+12'd2;
                            if({frame_length[11:8],rx_data}==0||frame_length[11:8]>=8)position<=0;
                        end else if(position==3)begin
                            command<=rx_data;frame_crc<=crc_byte(frame_crc,rx_data);
                            if(rx_data!=8'h30||frame_length<21||frame_length>1045)begin skip_left<=frame_length-1'b1;position<=0;end
                        end else begin
                            if(!reading_crc)frame_crc<=crc_byte(frame_crc,rx_data);
                            case(position)
                                4:version<=rx_data;5:op<=rx_data;
                                6,7,8,9:rid<={rid[23:0],rx_data};
                                10,11,12,13:req_sequence<={req_sequence[23:0],rx_data};
                                14,15,16,17:offset<={offset[23:0],rx_data};
                                18:count<={rx_data,8'b0};19:begin
                                    count[7:0]<=rx_data;candidate_crc<=stream_crc;
                                    payload_left<={count[10:8],rx_data};
                                    payload_active<={count[15:8],rx_data}!=0;
                                    reading_crc<={count[15:8],rx_data}==0;
                                end
                                default:begin
                                    if(position>=20&&position<20+count&&count<=1024)begin
                                        if(position<24)arg<={arg[23:0],rx_data};
                                        if(op==DATA_OP)candidate_crc<=crc_byte(candidate_crc,rx_data);
                                        if(last_valid&&rx_data!=(last_bank==2?fast2:last_bank==1?fast1:fast0))same_last<=0;
                                        if(prev_valid&&rx_data!=(prev_bank==2?fast2:prev_bank==1?fast1:fast0))same_prev<=0;
                                    end
                                end
                            endcase
                            if(position==last_position)begin
                                position<=0;reading_crc<=0;payload_active<=0;
                                if({received_crc[23:0],rx_data}==(frame_crc^32'hffffffff)&&version==1&&rid!=0&&count<=1024&&frame_length==21+count)begin
                                    activity<=1;mode<=VALIDATE;
                                end
                            end
                        end
                    end
                end
            end
        end
    end
endmodule
