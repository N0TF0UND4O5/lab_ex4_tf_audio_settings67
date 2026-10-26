`timescale 1ns/1ps
module tb_tft61_equivalence67;
 reg clk=0;always #5 clk=~clk;reg rst=1;reg[25:0]packet=26'h21ce124;
 tri[15:0]d0,d1;wire c0,s0,w0,r0,l0,b0,c1,s1,w1,r1,l1,b1;wire[15:0]id0,id1,pixel;wire ready0,ready1,fault0,fault1;wire[7:0]x;wire[8:0]y;wire[25:0]snap;
 tft_settings_display_reference #(.WAIT_20MS(3),.WAIT_120MS(5)) reference_display(clk,rst,packet,d0,c0,s0,w0,r0,l0,b0,id0,ready0,fault0);
 tft_settings_display #(.WAIT_20MS(3),.WAIT_120MS(5)) dut(clk,rst,packet,d1,c1,s1,w1,r1,l1,b1,id1,ready1,fault1,pixel,x,y,snap);
 tft_settings_renderer renderer(clk,x,y,snap,1'b0,pixel);
 assign d0=!r0 ? (reference_display.read_index==2 ? 16'h0093:reference_display.read_index==3 ? 16'h0041:16'h0000):16'hzzzz;
 assign d1=!r1 ? (dut.read_index==2 ? 16'h0093:dut.read_index==3 ? 16'h0041:16'h0000):16'hzzzz;
 integer cycles=0,writes=0;reg prev_wr=1;
 always @(posedge clk)begin #1;if(!rst)begin
  cycles=cycles+1;
  if({d0,c0,s0,w0,r0,l0,b0,id0,ready0,fault0}!=={d1,c1,s1,w1,r1,l1,b1,id1,ready1,fault1})$fatal(1,"TFT pin trace mismatch cycle%0d",cycles);
  if(!prev_wr&&w1)writes=writes+1;prev_wr=w1;
 end end
 initial begin repeat(4)@(negedge clk);rst=0;wait(ready1);@(negedge clk);packet=26'h25ce124;wait(dut.state!=12);wait(dut.state==12);repeat(20)@(negedge clk);
  if(fault1||writes<153600)$fatal(1,"TFT incomplete");
  $display("PASS TFT settings61 equivalence: %0d clocks, %0d writes, init + two full pages, identical pins/data/ready",cycles,writes);$finish;
 end
 initial begin #60000000;$fatal(1,"TFT timeout");end
endmodule
