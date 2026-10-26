`timescale 1ns/1ps
module tb_renderer67;
 reg clk=0;always #5 clk=~clk;
 reg[7:0]x=255;reg[8:0]y=511;reg[25:0]packet=26'h21ce124;
 reg small_text=0,valid=0,capture=0;
 wire[15:0]new_rgb,ref_rgb;
 tft_settings_renderer dut(clk,x,y,packet,small_text,new_rgb);
 tft_settings_renderer_reference reference_renderer(clk,x,y,packet,ref_rgb);
 reg[15:0]gold[0:76799];
 reg[2:0]valid_pipe=0,small_pipe=0,capture_pipe=0;
 integer pos0=0,pos1=0,pos2=0,checked=0;
 reg[15:0]expected=0,e0=0,e1=0,e2=0;
 always @(posedge clk)begin
  valid_pipe<={valid_pipe[1:0],valid};small_pipe<={small_pipe[1:0],small_text};capture_pipe<={capture_pipe[1:0],capture};
  pos0<=y*240+x;pos1<=pos0;pos2<=pos1;
  e0<=expected;e1<=e0;e2<=e1;
  #1;
  if(valid_pipe[2])begin
   if(new_rgb!==(small_pipe[2]?e2:ref_rgb))
    $fatal(1,"renderer mismatch small%0d pos%0d new%h expected%h",small_pipe[2],pos2,new_rgb,small_pipe[2]?e2:ref_rgb);
   if(capture_pipe[2])gold[pos2]=ref_rgb;
   checked=checked+1;
  end
 end
 task flush;
  begin @(negedge clk);valid=0;capture=0;repeat(4)@(negedge clk);end
 endtask
 task full_frame;
  input[25:0]cfg;integer a,b;
  begin
   flush;packet=cfg;small_text=0;capture=1;
   for(b=0;b<320;b=b+1)for(a=0;a<240;a=a+1)begin
    @(negedge clk);x=a;y=b;valid=1;capture=1;
   end
   flush;
  end
 endtask
 task small_frame;
  integer a,b,k;reg ink;
  begin
   small_text=1;capture=0;
   for(b=0;b<160;b=b+1)for(a=0;a<120;a=a+1)begin
    @(negedge clk);x=a*2;y=b*2;valid=1;k=b*2*240+a*2;
    ink=(gold[k]==16'hffff)||(gold[k+1]==16'hffff)||
        (gold[k+240]==16'hffff)||(gold[k+241]==16'hffff);
    expected=ink?16'hffff:gold[k];
   end
   flush;small_text=0;
  end
 endtask
 task value_row;
  input integer item,value;integer a,b;reg[20:0]cfg;
  begin
   flush;cfg=21'h1ce124;
   case(item)
    0:cfg[0]=value;1:cfg[2:1]=value;2:cfg[6:3]=value;
    3:cfg[9:7]=value;4:cfg[13:10]=value;5:cfg[14]=value;
    6:cfg[15]=value;7:cfg[17:16]=value;8:cfg[18]=value;
    9:cfg[19]=value;10:cfg[20]=value;
   endcase
   packet={1'b1,4'(item),cfg};small_text=0;
   for(b=42+item*24;b<66+item*24;b=b+1)for(a=0;a<240;a=a+1)begin
    @(negedge clk);x=a;y=b;valid=1;
   end
   flush;
  end
 endtask
 integer i,j,max_value;
 initial begin
  full_frame(26'h21ce124);
  $writememh("menu67_default_gold.hex",gold);
  small_frame;
  for(i=0;i<11;i=i+1)begin
   case(i)1,7:max_value=2;2,4:max_value=8;3:max_value=4;default:max_value=1;endcase
   for(j=0;j<=max_value;j=j+1)value_row(i,j);
  end
  full_frame(26'h35fffff);small_frame;
  full_frame(26'h2000000);small_frame;
  $display("PASS renderer67 %0d pixels: settings61 full-size equivalence, all41 legal setting values, three12px2x2 pooled pages",checked);
  $finish;
 end
 initial begin #30000000;$fatal(1,"renderer timeout");end
endmodule
