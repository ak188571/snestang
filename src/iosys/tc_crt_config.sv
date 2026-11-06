// One outstanding configuration mailbox. The source holds its bus until the
// pixel domain has applied it at a frame boundary. New source values coalesce.
module tc_crt_config (
    input wire clk, pclk, resetn,
    input wire [31:0] requested,
    input wire frame_start,
    output reg [31:0] active_config=0,
    output reg [31:0] applied_config=0
);
    reg [31:0] held=0, sent=0, pending=0;
    reg request=0, acknowledge=0, received=0, seen=0, pending_valid=0;
    (* async_reg = "true" *) reg [1:0] req_sync=0, ack_sync=0;

    always @(posedge clk) begin
        if (!resetn) begin
            held<=0;sent<=0;request<=0;ack_sync<=0;received<=0;applied_config<=0;
        end else begin
            ack_sync<={ack_sync[0],acknowledge};
            // active_config is stable before the acknowledgement crosses back.
            if(ack_sync[1]!=received)begin
                applied_config<=active_config;received<=ack_sync[1];
            end
            if(request==ack_sync[1] && requested!=sent)begin
                held<=requested;sent<=requested;request<=~request;
            end
        end
    end
    always @(posedge pclk) begin
        if(!resetn)begin
            req_sync<=0;seen<=0;pending<=0;pending_valid<=0;
            active_config<=0;acknowledge<=0;
        end else begin
            req_sync<={req_sync[0],request};
            if(req_sync[1]!=seen)begin
                pending<=held;pending_valid<=1;seen<=req_sync[1];
            end
            if(frame_start && pending_valid)begin
                active_config<=pending;acknowledge<=seen;pending_valid<=0;
            end
        end
    end
endmodule
