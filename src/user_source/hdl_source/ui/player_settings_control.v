module player_settings_control #(parameter integer DEBOUNCE_CYCLES=2000000)(
 input clk,rst,key_next,key_adjust,key_clear,
 input nav_up,nav_down,nav_left,nav_right,nav_center,nav_set,nav_reset,
 output settings_mode,output reg[3:0]selected,
 output reg[20:0]config_word,output reg config_toggle,output reg play_next,output reg clear_alarm
);
// Permanently editable TFT page. Hardware K2/K4 remain playback controls.
assign settings_mode=1'b1;
// Shared 1ms tick, all FFs still clocked by SD100MHz. Each key has a5bit
// stable-sample counter;21 sample edges guarantee at least20ms unchanged.
localparam PERIOD=DEBOUNCE_CYCLES<20?1:DEBOUNCE_CYCLES/20;
localparam TW=PERIOD<2?1:$clog2(PERIOD);
reg[TW-1:0]tick_count;reg tick;
wire[9:0]raw={key_clear,nav_reset,nav_set,nav_center,nav_right,nav_left,nav_down,nav_up,key_adjust,key_next};
reg[9:0]sync0,sync1,levels,presses;
reg board_armed,nav_armed;reg[4:0]board_ready,nav_ready;
always @(posedge clk or posedge rst)begin
 if(rst)begin tick_count<=0;tick<=0;sync0<=10'h3ff;sync1<=10'h3ff;end
 else begin
  sync0<=raw;sync1<=sync0;
  if(tick_count==PERIOD-1)begin tick_count<=0;tick<=1;end
  else begin tick_count<=tick_count+1'b1;tick<=0;end
 end
end
genvar k;
generate for(k=0;k<10;k=k+1)begin:filter
 reg[4:0]stable_count;
 always @(posedge clk or posedge rst)begin
  if(rst)begin stable_count<=0;levels[k]<=1;presses[k]<=0;end
  else begin
   presses[k]<=0;
   if(sync1[k]==levels[k])stable_count<=0;
   else if(tick)begin
    if(stable_count==20)begin stable_count<=0;levels[k]<=sync1[k];presses[k]<=levels[k]&&!sync1[k];end
    else stable_count<=stable_count+1'b1;
   end
  end
 end
end endgenerate
always @(posedge clk or posedge rst)begin
 if(rst)begin board_armed<=0;nav_armed<=0;board_ready<=0;nav_ready<=0;end
 else begin
  if(!board_armed)begin
   if(!(&sync1[1:0])||!(&levels[1:0]))board_ready<=0;
   else if(tick)begin if(board_ready==20)board_armed<=1;else board_ready<=board_ready+1'b1;end
  end
  if(!nav_armed)begin
   if(!(&sync1[8:2])||!(&levels[8:2]))nav_ready<=0;
   else if(tick)begin if(nav_ready==20)nav_armed<=1;else nav_ready<=nav_ready+1'b1;end
  end
 end
end
reg[20:0]cfg_next;reg[3:0]sel_next;
function[20:0]adjust;
 input[20:0]cfg;input[3:0]item;input increase;
 begin
  adjust=cfg;
  case(item)
   0:adjust[0]=~cfg[0];
   1:if(increase)adjust[2:1]=cfg[2:1]==2?0:cfg[2:1]+1'b1;
     else adjust[2:1]=cfg[2:1]==0?2:cfg[2:1]-1'b1;
   2:if(increase)adjust[6:3]=cfg[6:3]==8?8:cfg[6:3]+1'b1;
     else adjust[6:3]=cfg[6:3]==0?0:cfg[6:3]-1'b1;
   3:if(increase)adjust[9:7]=cfg[9:7]==4?4:cfg[9:7]+1'b1;
     else adjust[9:7]=cfg[9:7]==0?0:cfg[9:7]-1'b1;
   4:if(increase)adjust[13:10]=cfg[13:10]==8?8:cfg[13:10]+1'b1;
     else adjust[13:10]=cfg[13:10]==0?0:cfg[13:10]-1'b1;
   5:adjust[14]=~cfg[14];
   6:adjust[15]=~cfg[15];
   7:if(increase)adjust[17:16]=cfg[17:16]==2?0:cfg[17:16]+1'b1;
     else adjust[17:16]=cfg[17:16]==0?2:cfg[17:16]-1'b1;
   8:adjust[18]=~cfg[18];
   9:adjust[19]=~cfg[19];
   10:adjust[20]=~cfg[20];
  endcase
 end
endfunction
always @*begin
 cfg_next=config_word;sel_next=selected;
 if(board_armed&&presses[1])cfg_next[0]=~cfg_next[0];
 if(nav_armed)begin
  // One navigation event per cycle; restore > home > move > adjust > center.
  if(presses[8])begin cfg_next=21'h1ce124;sel_next=0;end
  else if(presses[7])sel_next=0;
  else if(presses[2])sel_next=selected==0?10:selected-1'b1;
  else if(presses[3])sel_next=selected==10?0:selected+1'b1;
  else if(presses[4])cfg_next=adjust(cfg_next,selected,1'b0);
  else if(presses[5])cfg_next=adjust(cfg_next,selected,1'b1);
  else if(presses[6]&&(selected==0||selected==1||selected>=5))cfg_next=adjust(cfg_next,selected,1'b1);
 end
end
always @(posedge clk or posedge rst)begin
 if(rst)begin selected<=0;config_word<=21'h1ce124;config_toggle<=0;play_next<=0;clear_alarm<=0;end
 else begin
  play_next<=board_armed&&presses[0];clear_alarm<=board_armed&&presses[9];
  selected<=sel_next;config_word<=cfg_next;
  if(cfg_next!=config_word||sel_next!=selected)config_toggle<=~config_toggle;
 end
end
endmodule
// Bundled data settles for two pixel clocks before its three-stage toggle.
// Human changes are >=20ms apart. Apply the complete packet at VS blanking.
module player_settings_bridge(
 input clk,rst,input[25:0]source_packet,input source_toggle,vs,
 output reg[25:0]frame_packet
);
reg[25:0]data0,data1,pending;
reg[2:0]tag;reg seen,vs_prev;
always @(posedge clk or posedge rst)begin
 if(rst)begin data0<=26'h21ce124;data1<=26'h21ce124;pending<=26'h21ce124;frame_packet<=26'h21ce124;tag<=0;seen<=0;vs_prev<=1;end
 else begin
  data0<=source_packet;data1<=data0;tag<={tag[1:0],source_toggle};vs_prev<=vs;
  if(tag[2]!=seen)begin pending<=data1;seen<=tag[2];end
  if(vs_prev&&!vs)frame_packet<=pending;
 end
end
endmodule
