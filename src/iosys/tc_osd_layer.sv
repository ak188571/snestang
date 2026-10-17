// Logical 256x224 OSD canvas, independent of the game's framebuffer dimensions.
// Window bytes are x,y,width,height in 8x8 character cells. Bounds update at frame start.
module tc_osd_layer #(parameter XSTART=160,YSTART=0,VIEW_WIDTH=960,VIEW_HEIGHT=720) (
    input wire pclk, resetn,
    input wire [10:0] cx,
    input wire [9:0] cy,
    input wire active,
    input wire [31:0] window,
    input wire window_toggle,
    output reg [7:0] x=0,y=0,
    output wire pixel,
    output reg visible=0
);
    reg [10:0] hx=0,vy=0;
    reg [31:0] bus1=32'h0000201c,bus2=32'h0000201c;
    reg [2:0] event_sync=0;
    reg seen=0;
    reg [1:0] active_sync=0;
    reg [31:0] pending=32'h0000201c,current=32'h0000201c;
    reg [1:0] mask_pipe=0;
    wire osd_inside = cx>=XSTART && cx<XSTART+VIEW_WIDTH && cy>=YSTART && cy<YSTART+VIEW_HEIGHT &&
        {4'b0,x[7:3]} >= {1'b0,current[31:24]} &&
        {4'b0,x[7:3]} < ({1'b0,current[31:24]}+{1'b0,current[15:8]}) &&
        {4'b0,y[7:3]} >= {1'b0,current[23:16]} &&
        {4'b0,y[7:3]} < ({1'b0,current[23:16]}+{1'b0,current[7:0]});
    assign pixel=mask_pipe[1];
    always @(posedge pclk) begin
        if(!resetn) begin
            hx<=0;vy<=0;x<=0;y<=0;
            bus1<=32'h0000201c;bus2<=32'h0000201c;
            event_sync<=0;seen<=0;active_sync<=0;visible<=0;
            pending<=32'h0000201c;current<=32'h0000201c;mask_pipe<=0;
        end else begin
            bus1<=window;bus2<=bus1;
            event_sync<={event_sync[1:0],window_toggle};
            active_sync<={active_sync[0],active};
            if(event_sync[2]!=seen)begin pending<=bus2;seen<=event_sync[2];end
            if(cx==0&&cy==0)begin current<=pending;visible<=active_sync[1];end
            // Constant-ratio accumulators avoid a wide combinational divider.
            if(cx==XSTART-1)begin x<=0;hx<=0;end
            else if(cx>=XSTART&&cx<XSTART+VIEW_WIDTH)begin
                if(hx+11'd256>=11'(VIEW_WIDTH))begin hx<=hx+11'd256-11'(VIEW_WIDTH);x<=x+1'b1;end
                else hx<=hx+11'd256;
            end
            if(cx==0)begin
                if(cy==YSTART)begin y<=0;vy<=0;end
                else if(cy>YSTART&&cy<YSTART+VIEW_HEIGHT)begin
                    if(vy+11'd224>=11'(VIEW_HEIGHT))begin vy<=vy+11'd224-11'(VIEW_HEIGHT);y<=y+1'b1;end
                    else vy<=vy+11'd224;
                end
            end
            // textdisp has a two-clock read latency; delay the opacity identically.
            mask_pipe<={mask_pipe[0],visible&&osd_inside};
        end
    end
endmodule
