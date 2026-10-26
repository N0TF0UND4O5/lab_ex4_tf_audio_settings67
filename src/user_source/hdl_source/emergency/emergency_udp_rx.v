// Receive-only control channel. No MAC/IP/UDP echo engine is instantiated.
// Host uses directed UDP broadcast, port5000. Commit only after Ethernet FCS
// and IPv4 header checksum pass. Payload:0/1/2/3 or command:seconds (e.g.1:30).
module emergency_udp_rx(input rx_clk,rst,input[3:0]rx_data,input rx_ctl,
 input acknowledge,output[9:0]command,output request);
reg[2:0]reset_pipe;
always @(posedge rx_clk or posedge rst)
 if(rst)reset_pipe<=7;else reset_pipe<={reset_pipe[1:0],1'b0};
wire[7:0]data;wire dv,fall_ctl;
genvar k;
generate for(k=0;k<4;k=k+1)begin:ddr
 EG_LOGIC_IDDR #(.ASYNCRST("ENABLE"),.PIPEMODE("PIPED")) u_ddr(
 .clk(rx_clk),.rst(reset_pipe[2]),.d(rx_data[k]),.q0(data[k]),.q1(data[k+4]));
end endgenerate
EG_LOGIC_IDDR #(.ASYNCRST("ENABLE"),.PIPEMODE("PIPED")) u_ctl(
 .clk(rx_clk),.rst(reset_pipe[2]),.d(rx_ctl),.q0(dv),.q1(fall_ctl));
emergency_packet_rx u_packet(.clk(rx_clk),.rst(reset_pipe[2]),.data(data),
 .dv(dv),.er(dv^fall_ctl),.acknowledge(acknowledge),.command(command),.request(request));
endmodule

module emergency_packet_rx #(
 parameter[31:0]BROADCAST_IP=32'ha9feffff
)(input clk,rst,input[7:0]data,input dv,er,input acknowledge,
 output reg[9:0]command,output reg request);
// Register DDR outputs and header classifiers before the packet FSM.
reg[7:0]d;reg dv_q,er_q;
reg is_zero,is_08,is_45,is_17,is_colon,is_digit,is_command,fragment_bad,is_ff;
always @(posedge clk or posedge rst)begin
 if(rst)begin d<=0;dv_q<=0;er_q<=0;is_zero<=1;is_08<=0;is_45<=0;is_17<=0;is_colon<=0;is_digit<=0;is_command<=0;fragment_bad<=0;is_ff<=0;end
 else begin
  d<=data;dv_q<=dv;er_q<=er;
  is_zero<=data==0;is_08<=data==8'h08;is_45<=data==8'h45;is_17<=data==17;
  is_colon<=data==":";is_digit<=data>="0"&&data<="9";is_command<=data>="0"&&data<="3";
  fragment_bad<=(data&8'hbf)!=0;is_ff<=data==8'hff;
 end
end
reg[1:0]phase;
reg[10:0]position;
reg[31:0]crc;
reg broadcast_match,limited_match;
reg bad;
reg ip_short,ip_long,udp_short,udp_long;
reg[19:0]ip_sum;
reg[7:0]ip_hi;
reg[1:0]code;
reg[7:0]seconds;
reg[3:0]tens;
reg[2:0]ack_sync;
function[31:0]crc_byte;
 input[31:0]c;input[7:0]d;integer n;reg[31:0]v;
 begin v=c;for(n=0;n<8;n=n+1)v=(v[0]^d[n])?((v>>1)^32'hedb88320):(v>>1);crc_byte=v;end
endfunction
wire[16:0]fold={1'b0,ip_sum[15:0]}+ip_sum[19:16];
wire[15:0]folded=fold[15:0]+fold[16];
// Command datagrams have total IP length29 or32. A minimum64-byte frame
// already contains the entire payload/FCS; compare fixed formats without adders.
wire valid_frame=!bad&&position>=64&&crc==32'hdebb20e3
 &&(broadcast_match||limited_match)&&folded==16'hffff
 &&((ip_short&&udp_short)||(ip_long&&udp_long));
always @(posedge clk or posedge rst)begin
 if(rst)begin
  phase<=0;position<=0;crc<=32'hffffffff;broadcast_match<=1;limited_match<=1;
  bad<=0;ip_short<=0;ip_long<=0;udp_short<=0;udp_long<=0;ip_sum<=0;ip_hi<=0;
  code<=0;seconds<=0;tens<=0;ack_sync<=0;command<=0;request<=0;
 end else begin
  ack_sync<={ack_sync[1:0],acknowledge};
  if(!dv_q)begin
   if(phase==2&&valid_frame&&request==ack_sync[2])begin
    command<={code,seconds};request<=~request;
   end
   phase<=0;
  end else case(phase)
   0:begin
    phase<=d==8'h55 ? 1 : 3;position<=0;crc<=32'hffffffff;
    broadcast_match<=1;limited_match<=1;bad<=er_q;
    ip_short<=0;ip_long<=0;udp_short<=0;udp_long<=0;ip_sum<=0;ip_hi<=0;
    code<=0;seconds<=0;tens<=0;
   end
   1:begin
    if(d==8'hd5)phase<=2;else if(d!=8'h55)phase<=3;
    if(er_q)bad<=1;
   end
   2:begin
    crc<=crc_byte(crc,d);
    if(position==2047)bad<=1;else position<=position+1'b1;
    if(er_q)bad<=1;
    if(position<6&&!is_ff)bad<=1;
    if(position>=14&&position<34)begin
     if(!position[0])ip_hi<=d;else ip_sum<=ip_sum+{ip_hi,d};
    end
    case(position)
     12:if(!is_08)bad<=1;
     13:if(!is_zero)bad<=1;
     14:if(!is_45)bad<=1; // IPv4,20-byte header; no options
     16:if(!is_zero)bad<=1;
     17:begin ip_short<=d==29;ip_long<=d==32;end
     20:if(fragment_bad)bad<=1; // DF allowed; no MF/reserved/fragment
     21:if(!is_zero)bad<=1;
     22:if(is_zero)bad<=1;
     23:if(!is_17)bad<=1;
     30:begin if(d!=BROADCAST_IP[31:24])broadcast_match<=0;if(!is_ff)limited_match<=0;end
     31:begin if(d!=BROADCAST_IP[23:16])broadcast_match<=0;if(!is_ff)limited_match<=0;end
     32:begin if(d!=BROADCAST_IP[15:8])broadcast_match<=0;if(!is_ff)limited_match<=0;end
     33:begin if(d!=BROADCAST_IP[7:0])broadcast_match<=0;if(!is_ff)limited_match<=0;end
     36:if(d!=8'h13)bad<=1;
     37:if(d!=8'h88)bad<=1;
     38:if(!is_zero)bad<=1;
     39:begin udp_short<=d==9;udp_long<=d==12;end
     42:begin
      if(!is_command)bad<=1;
      code<=d[1:0];
      case(d)
       "1":seconds<=15;
       "2":seconds<=60;
       "3":seconds<=5;
       default:seconds<=0;
      endcase
     end
     43:if(udp_long&&!is_colon)bad<=1;
     44:if(udp_long)begin
      if(!is_digit)bad<=1;
      tens<=d[3:0];
     end
     45:if(udp_long)begin
      if(!is_digit)bad<=1;
      seconds<=({4'd0,tens}<<3)+({4'd0,tens}<<1)+{4'd0,d[3:0]};
     end
     default:;
    endcase
   end
   default:;
  endcase
 end
end
endmodule
