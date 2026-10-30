// Experimental Full-Speed receive validator at 96 MHz, up to 32 payload bytes.
// Independent from the preserved 12 MHz Low-Speed path; not board-integrated yet.
// Input uses the PHY bit sampling point; outputs contain payload only.
module usb_fs_rx_guard(
 input wire clk, resetn, arm, sample, dp, dm, publish_data,
 output reg done, ok, accepted, timed_out,
 output wire [7:0] packet_pid,
 output wire [255:0] payload,
 output reg ready, strobe,
 output reg [7:0] value,
 output reg [5:0] length
);
 assign packet_pid=pid;
 for(genvar g=0;g<32;g=g+1)begin:payload_bytes
  assign payload[8*g+:8]=ok && g<int'(length) ? staging[g] : 8'd0;
 end
 // 160 clocks after arm bounds absent response (20 FS bit times).
 // 4096 clocks after SOP bounds a truncated 32-byte packet, including stuffing.
 reg started=0;
 reg [12:0] deadline=0;
 wire expired=active && ((!started && deadline==159) || (started && deadline==4095));
 reg active=0, bad=0;
 reg [7:0] shift=0, pid=0;
 reg [2:0] bits=0, ones=0;
 reg [6:0] bytes_seen=0;
 reg [15:0] crc=16'hffff;
 reg [7:0] staging[0:31];
 reg [5:0] se0_count=0;
 reg [1:0] se1_count=0;
 reg [5:0] emit_index=0;
 reg emit_phase=0;
 reg previous_dp=1;
 wire decoded_bit=previous_dp ~^ dp;
 wire [7:0] completed={decoded_bit,shift[7:1]};
 wire data_pid=(pid==8'hc3 || pid==8'h4b);
 wire good_data=data_pid && bytes_seen>=4 && bytes_seen<=36 && crc==16'hb001;
 wire good_ack=(pid==8'hd2 || pid==8'h5a || pid==8'h1e) && bytes_seen==2;
 // A CRC-valid byte boundary may be followed only by a short all-one
 // tail. Retain its CRC result and length without publishing before EOP.
 reg tail_valid=0,tail_data=0;
 reg [2:0] tail_bits=0;
 reg [5:0] tail_length=0;
 wire packet_boundary=bits==0 && ones!=6 && (good_data || good_ack);
 wire valid_tail=tail_valid && tail_bits!=0 && tail_bits<=6 && bits==tail_bits && ones<=6;
 wire final_packet=packet_boundary || valid_tail;
 wire final_data=(packet_boundary && good_data) || (valid_tail && tail_data);
 wire [5:0] final_length=valid_tail ? tail_length : 6'(bytes_seen-4);
 integer i;
 always @(posedge clk) begin
  done<=0;
  if(!resetn || arm) begin
   active<=arm;started<=0;deadline<=0;accepted<=0;timed_out<=0;bad<=0;shift<=0;pid<=0;bits<=0;ones<=0;bytes_seen<=0;
   crc<=16'hffff;se0_count<=0;se1_count<=0;ready<=0;strobe<=0;ok<=0;
   value<=0;length<=0;emit_index<=0;emit_phase<=0;
   previous_dp<=1;
   tail_valid<=0;tail_data<=0;tail_bits<=0;tail_length<=0;
   for(i=0;i<32;i=i+1)staging[i]<=0;
  end else begin
   if(ready) begin
    if(!emit_phase)begin value<=staging[emit_index[4:0]];strobe<=1;emit_phase<=1;end
    else begin
     strobe<=0;emit_phase<=0;
     if(emit_index+1>=length)ready<=0;
     else emit_index<=emit_index+1'b1;
    end
   end
   if(active)begin
    if(!started && !dp && dm)begin started<=1;deadline<=0;end
    else deadline<=deadline+1'b1;
    if(expired)begin active<=0;done<=1;ok<=0;accepted<=0;timed_out<=1;ready<=0;strobe<=0;end
   end
   if(active && !expired && started)begin
    // Ignore a companion pin's brief crossover; reject persistent SE1.
    if(dp && dm)begin
     if(se1_count!=3)se1_count<=se1_count+1'b1;
     if(se1_count>=2)bad<=1;
    end else se1_count<=0;
    if(!bad && packet_boundary)begin
     tail_valid<=1;tail_data<=good_data;tail_bits<=0;
     tail_length<=good_data ? 6'(bytes_seen-4) : 0;
    end
    if(!dp && !dm)begin
     if(se0_count!=63)se0_count<=se0_count+1'b1;
    end else if(se0_count>=7)begin
     active<=0;done<=1;
     // 82 ns can be sampled as seven 96 MHz clocks: accept >=7.
     // <=22 is a digital bound, not a USB source timing specification.
     if(dp && !dm && se0_count<=22 && !bad && final_packet)begin
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
     if(dp && dm)begin end
     else if(sample)begin
     previous_dp<=dp;
     if(ones==6)begin
      if(tail_valid && tail_bits!=0)tail_valid<=0;
      if(decoded_bit)bad<=1;
      ones<=0;
     end else begin
      if(tail_valid)begin
       if(!decoded_bit)tail_valid<=0;
       else if(tail_bits!=7)tail_bits<=tail_bits+1'b1;
      end
      ones<=decoded_bit ? ones+3'd1 : 3'd0;
      shift<=completed;
      bits<=bits+1'b1;
      if(bytes_seen>=2)
       crc<=(crc[0]^decoded_bit) ? (crc>>1)^16'ha001 : crc>>1;
      if(bits==7)begin
       if(bytes_seen==0 && completed!=8'h80)bad<=1;
       if(bytes_seen==1)pid<=completed;
       if(bytes_seen>=2 && bytes_seen<34)staging[bytes_seen-2]<=completed;
       if(bytes_seen==63)bad<=1;else bytes_seen<=bytes_seen+1'b1;
      end
     end
    end
   end
   end
  end
 end
endmodule
