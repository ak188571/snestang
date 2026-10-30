// Experimental low-speed packet validator. Not yet approved for hardware.
// Input uses the PHY bit sampling point; outputs contain payload only.
module usb_rx_guard(
 input wire clk, resetn, arm, sample, dp, dm, publish_data,
 output reg done=0, ok=0, accepted=0, timed_out=0,
 output wire [7:0] packet_pid,
 output wire [63:0] payload,
 output reg ready=0, strobe=0,
 output reg [7:0] value=0,
 output reg [3:0] length=0
);
 assign packet_pid=pid;
 assign payload={staging[7],staging[6],staging[5],staging[4],staging[3],staging[2],staging[1],staging[0]};
 // 160 clocks after arm, conservatively later than 18 LS bit times after TX EOP.
 // A separate 1152-clock cap bounds a started but truncated/malformed packet.
 reg started=0;
 reg [10:0] deadline=0;
 wire expired=active && ((!started && deadline==159) || (started && deadline==1151));
 reg active=0, bad=0;
 reg [7:0] shift=0, pid=0;
 reg [2:0] bits=0, ones=0;
 reg [4:0] bytes_seen=0;
 reg [15:0] crc=16'hffff;
 reg [7:0] staging[0:7];
 reg [5:0] se0_count=0;
 reg [3:0] emit_index=0;
 reg emit_phase=0;
 reg previous_dm=1;
 wire decoded_bit=previous_dm ~^ dm;
 wire [7:0] completed={decoded_bit,shift[7:1]};
 wire data_pid=(pid==8'hc3 || pid==8'h4b);
 wire good_data=data_pid && bytes_seen>=4 && bytes_seen<=12 && crc==16'hb001;
 wire good_ack=(pid==8'hd2 || pid==8'h5a || pid==8'h1e) && bytes_seen==2;
 // A CRC-valid byte boundary may be followed only by a short all-one
 // tail. Retain its CRC result and length without publishing before EOP.
 reg tail_valid=0,tail_data=0;
 reg [2:0] tail_bits=0;
 reg [3:0] tail_length=0;
 wire packet_boundary=bits==0 && ones!=6 && (good_data || good_ack);
 wire valid_tail=tail_valid && tail_bits!=0 && tail_bits<=6 && bits==tail_bits && ones<=6;
 wire final_packet=packet_boundary || valid_tail;
 wire final_data=(packet_boundary && good_data) || (valid_tail && tail_data);
 wire [3:0] final_length=valid_tail ? tail_length : 4'(bytes_seen-4);
 integer i;
 always @(posedge clk) begin
  done<=0;
  if(!resetn || arm) begin
   active<=arm;started<=0;deadline<=0;accepted<=0;timed_out<=0;bad<=0;shift<=0;pid<=0;bits<=0;ones<=0;bytes_seen<=0;
   crc<=16'hffff;se0_count<=0;ready<=0;strobe<=0;ok<=0;
   value<=0;length<=0;emit_index<=0;emit_phase<=0;
   previous_dm<=1;
   tail_valid<=0;tail_data<=0;tail_bits<=0;tail_length<=0;
   for(i=0;i<8;i=i+1)staging[i]<=0;
  end else begin
   if(ready) begin
    if(!emit_phase)begin value<=staging[emit_index[2:0]];strobe<=1;emit_phase<=1;end
    else begin
     strobe<=0;emit_phase<=0;
     if(emit_index+1>=length)ready<=0;
     else emit_index<=emit_index+1'b1;
    end
   end
   if(active)begin
    if(!started && dp && !dm)begin started<=1;deadline<=0;end
    else deadline<=deadline+1'b1;
    if(expired)begin active<=0;done<=1;ok<=0;accepted<=0;timed_out<=1;ready<=0;strobe<=0;end
   end
   if(active && !expired && started)begin
    if(!bad && packet_boundary)begin
     tail_valid<=1;tail_data<=good_data;tail_bits<=0;
     tail_length<=good_data ? 4'(bytes_seen-4) : 0;
    end
    if(!dp && !dm)begin
     if(se0_count!=63)se0_count<=se0_count+1'b1;
    end else if(se0_count>=8)begin
     active<=0;done<=1;
     // 670 ns may be observed as eight 12 MHz samples. The upper digital
     // margin is an implementation limit, not a new USB specification value.
     if(dm && !dp && se0_count<=22 && !bad && final_packet)begin
      ok<=1;
      if(final_data)length<=final_length;
      if(final_data && publish_data)begin
       accepted<=1;length<=final_length;emit_index<=0;emit_phase<=0;
       if(final_length!=0)ready<=1;
      end
     end else ok<=0;
    end else begin
     // Short SE0 during an ordinary differential transition is not EOP.
     se0_count<=0;
     if(dp && dm)bad<=1;
     else if(sample)begin
     previous_dm<=dm;
     if(ones==6)begin
      if(tail_valid && tail_bits!=0)tail_valid<=0;
      if(decoded_bit)bad<=1;
      ones<=0;
     end else begin
      if(tail_valid)begin
       if(!decoded_bit)tail_valid<=0;
       else if(tail_bits!=7)tail_bits<=tail_bits+1'b1;
      end
      ones<=decoded_bit ? ones+1'b1 : 0;
      shift<=completed;
      bits<=bits+1'b1;
      if(bytes_seen>=2)
       crc<=(crc[0]^decoded_bit) ? (crc>>1)^16'ha001 : crc>>1;
      if(bits==7)begin
       if(bytes_seen==0 && completed!=8'h80)bad<=1;
       if(bytes_seen==1)pid<=completed;
       if(bytes_seen>=2 && bytes_seen<10)staging[bytes_seen-2]<=completed;
       if(bytes_seen==31)bad<=1;else bytes_seen<=bytes_seen+1'b1;
      end
     end
    end
   end
   end
  end
 end
endmodule
