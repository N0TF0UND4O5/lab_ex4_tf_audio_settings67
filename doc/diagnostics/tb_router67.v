`timescale 1ns/1ps
module tb_router67;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,sw1=0,de=0,vs=1;reg[23:0]rgb=0;reg[25:0]packet=26'h21ce124;
 reg subtitle_enable=1,scroll_enable=0,pause_scroll=0;
 wire[23:0]sub_rgb,out;wire sub_de,sub_vs,image_switch;wire ode,ovs,active;tri[15:0]db;wire cs,rs,wr,rd,lr,bl;wire[15:0]id;wire ready,fault;
 settings_display_router #(.DEBOUNCE_CYCLES(8)) dut(clk,rst,sw1,packet,sub_rgb,sub_de,sub_vs,out,ode,ovs,active,db,cs,rs,wr,rd,lr,bl,id,ready,fault);
 hdmi_subtitle_osd #(.SCROLL_ENABLE(1)) subtitles(.pause_scroll(pause_scroll),.scroll_enable(scroll_enable),.clk(clk),.rst(rst),.enable(subtitle_enable),.rgb_in(rgb),.de_in(de),.vs_in(vs),.buffer0_image(3'd0),.buffer1_image(3'd0),.active_buffer(1'b0),.auto_mode_in(1'b0),.image_valid_in(1'b0),.buffer0_size(24'd0),.buffer1_size(24'd0),.image_total(4'd8),.image_switch(image_switch),.rgb_out(sub_rgb),.de_out(sub_de),.vs_out(sub_vs));
 reg[15:0]subfont[0:1023];
 integer subtitle_mode=1,scroll_position=0,cx,cy,ci,sx,sy,tx,gi;
 function integer subglyph;input integer index;begin case(index)
 0:subglyph=46;1:subglyph=47;2:subglyph=48;3:subglyph=49;4:subglyph=50;
 8:subglyph=51;9:subglyph=52;10:subglyph=53;11:subglyph=54;12:subglyph=53;13:subglyph=55;14:subglyph=56;default:subglyph=0;endcase end endfunction
 reg[15:0]gold[0:76799];reg[23:0]preview[0:307199];
 reg[23:0]expected=0,e0,e1,e2,e3,e4,e5,e6;reg[6:0]dp=0,vp=127,valid=0;reg sample=0;
 integer checked=0,panels=0,xx,yy,base;reg[15:0]g;reg font_on;reg[7:0]r,gc,b;
 always @(posedge clk)begin
  e0<=expected;e1<=e0;e2<=e1;e3<=e2;e4<=e3;e5<=e4;e6<=e5;dp<={dp[5:0],de};vp<={vp[5:0],vs};valid<={valid[5:0],sample};
  #1;
  if(valid[6])begin
   if(out!==e6||ode!==dp[6]||ovs!==vp[6])$fatal(1,"router pixel%0d out%h expected%h DE%b/%b VS%b/%b",checked,out,e6,ode,dp[6],ovs,vp[6]);
   checked=checked+1;
  end
  if(active&&(bl!==0||cs!==1||wr!==1||rd!==1))$fatal(1,"TFT must be off and bus parked during HDMI menu");
 end
 task send;
  input integer x,y;input en,v,menu;
  begin
   @(negedge clk);de=en;vs=v;rgb={8'(x/3),8'(y/2),8'(48+((x/32+y/32)%2)*80)};sample=1;
   expected=en?rgb:24'd0;
   if(en&&subtitle_mode!=0&&x>=16&&x<624&&y>=356&&y<386)begin
    expected={1'b0,rgb[23:17],1'b0,rgb[15:9],1'b0,rgb[7:1]};
    tx=subtitle_mode==2 ? x-608+scroll_position:x-200;
    if(y>=362&&y<378&&tx>=0&&tx<240&&(subtitle_mode!=2||(x>=32&&x<608)))begin
     gi=subglyph(tx/16);
     if(subfont[gi*16+y-362][15-(tx%16)])expected=24'hffffff;
    end
   end
   if(en&&menu&&x>=16&&x<624&&y>=392&&y<464)begin
    r=rgb[23:16]>>1;gc=rgb[15:8]>>1;b=rgb[7:0]>>1;expected={r,gc,b};font_on=0;
    cx=(x-28)%146;ci=((x-28)/146)*3;cy=-1;
    if(y>=414&&y<426)cy=y-414;
    else if(y>=430&&y<442)begin cy=y-430;ci=ci+1;end
    else if(y>=446&&y<458)begin cy=y-446;ci=ci+2;end
    if(x>=28&&cy>=0&&ci<11)begin
     if(cx<137&&ci==0)expected={8'(r+16),8'(gc+24),8'(b+48)};
     if(cx<60||(cx>=88&&cx<136))begin
      sx=cx<60 ? 8+cx*2:132+(cx-88)*2;sy=42+ci*24+cy*2;base=sy*240+sx;
      font_on=gold[base]==16'hffff||gold[base+1]==16'hffff||gold[base+240]==16'hffff||gold[base+241]==16'hffff;
     end
    end
    if(x>=28&&x<76&&y>=395&&y<407)begin
     sx=72+(x-28)*2;sy=10+(y-395)*2;base=sy*240+sx;
     font_on=gold[base]==16'hffff||gold[base+1]==16'hffff||gold[base+240]==16'hffff||gold[base+241]==16'hffff;
    end
    if(x<20)expected=24'h80c8ff;
    if(font_on)expected=24'hffffff;
    panels=panels+1;
   end
  end
 endtask
 task frame;
  input menu,steer,capture;
  begin
   send(0,0,0,1,menu);send(0,0,0,0,menu);repeat(20)send(0,0,0,0,menu);
   if(active!==menu)$fatal(1,"mode did not commit at frame boundary");
   for(yy=0;yy<480;yy=yy+1)begin
    for(xx=0;xx<640;xx=xx+1)begin
     if(steer&&yy==200&&xx==0)begin sw1=1;packet=26'h01ce124;end
     send(xx,yy,1,0,menu);
     if(capture)preview[yy*640+xx]=expected;
    end
    repeat(8)send(0,yy,0,0,menu);
   end
  end
 endtask
 initial begin
  $readmemh("menu67_default_gold.hex",gold);$readmemh("settings67_subtitle_font.hex",subfont);
  repeat(4)@(negedge clk);rst=0;
  sw1=1;repeat(3)send(0,0,0,1,0);sw1=0;repeat(15)send(0,0,0,1,0);
  frame(0,1,0);
  if(dut.frame_packet!==26'h21ce124)$fatal(1,"settings changed within frame");
  frame(1,0,1);
  if(dut.frame_packet!==26'h01ce124)$fatal(1,"settings not committed at boundary");$writememh("settings67_hdmi_preview.hex",preview);
  subtitle_enable=0;subtitle_mode=0;frame(1,0,0);
  subtitle_enable=1;scroll_enable=1;subtitle_mode=2;scroll_position=1;
  sw1=0;repeat(20)send(0,0,0,0,1);frame(0,0,0);
  if(subtitles.scroll_offset!==10'd1)$fatal(1,"scroll must advance once per frame");
  pause_scroll=1;frame(0,0,0);
  if(subtitles.scroll_offset!==10'd1)$fatal(1,"emergency pause did not freeze subtitle");
  sample=0;repeat(6)@(negedge clk);
  if(panels!=87552)$fatal(1,"wrong panel area %0d",panels);
  $display("PASS router67 %0d cycles: RGB/DE/VS, 87552 panel pixels, independent subtitle on/off/static/scroll/pause, alpha/text/border, debounce, frame commit, settings snapshot, TFT isolation",checked);$finish;
 end
 initial begin #60000000;$fatal(1,"router timeout");end
endmodule
