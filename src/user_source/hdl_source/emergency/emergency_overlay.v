// Full-canvas emergency layer,640x480. Two-cycle synchronous-font pipeline.
module emergency_overlay(input clk,rst,input[1:0]state,input[7:0]seconds,
 input blink_warning,blink_emergency,input[23:0]rgb_in,input de_in,vs_in,
 output reg[23:0]rgb_out,output reg de_out,vs_out,output reg[1:0]frame_state);
reg de_prev,vs_prev;reg[9:0]x_count,y_count;
reg[7:0]frame_seconds;reg warn_flash,emerg_flash;
wire[9:0]x=de_prev?x_count:10'd0;wire[9:0]y=y_count;
always @(posedge clk or posedge rst)begin
 if(rst)begin de_prev<=0;vs_prev<=1;x_count<=0;y_count<=0;frame_state<=0;frame_seconds<=0;warn_flash<=0;emerg_flash<=0;end
 else begin
  de_prev<=de_in;vs_prev<=vs_in;
  if(vs_prev&&!vs_in)begin
   y_count<=0;frame_state<=state;frame_seconds<=seconds;warn_flash<=blink_warning;emerg_flash<=blink_emergency;
  end else if(de_prev&&!de_in)y_count<=y_count+1'b1;
  if(de_in)x_count<=x+1'b1;else x_count<=0;
 end
end
function[3:0]decimal_tens;input[7:0]v;
 begin
  if(v>=90)decimal_tens=9;else if(v>=80)decimal_tens=8;else if(v>=70)decimal_tens=7;
  else if(v>=60)decimal_tens=6;else if(v>=50)decimal_tens=5;else if(v>=40)decimal_tens=4;
  else if(v>=30)decimal_tens=3;else if(v>=20)decimal_tens=2;else if(v>=10)decimal_tens=1;else decimal_tens=0;
 end
endfunction
wire[3:0]tens=decimal_tens(frame_seconds);
wire[7:0]ones=frame_seconds-({4'd0,tens}<<3)-({4'd0,tens}<<1);
function[5:0]text_glyph;input[2:0]line;input[3:0]index;begin case({line,index})
7'd0:text_glyph=6'd11;
7'd1:text_glyph=6'd12;
7'd2:text_glyph=6'd13;
7'd3:text_glyph=6'd14;
7'd16:text_glyph=6'd15;
7'd17:text_glyph=6'd16;
7'd18:text_glyph=6'd17;
7'd19:text_glyph=6'd18;
7'd32:text_glyph=6'd19;
7'd33:text_glyph=6'd20;
7'd34:text_glyph=6'd21;
7'd35:text_glyph=6'd22;
7'd36:text_glyph=6'd23;
7'd37:text_glyph=6'd24;
7'd48:text_glyph=6'd25;
7'd49:text_glyph=6'd17;
7'd50:text_glyph=6'd18;
7'd51:text_glyph=6'd26;
7'd52:text_glyph=6'd27;
7'd53:text_glyph=6'd28;
7'd54:text_glyph=6'd29;
7'd64:text_glyph=6'd14;
7'd65:text_glyph=6'd30;
7'd66:text_glyph=6'd31;
7'd67:text_glyph=6'd32;
7'd80:text_glyph=6'd33;
7'd81:text_glyph=6'd34;
7'd82:text_glyph=6'd35;
7'd83:text_glyph=6'd36;
7'd96:text_glyph=6'd37;
7'd97:text_glyph=6'd38;
7'd98:text_glyph=6'd39;
7'd99:text_glyph=6'd40;
7'd112:text_glyph=6'd41;
7'd113:text_glyph=6'd42;
7'd114:text_glyph=6'd43;
default:text_glyph=0;endcase end endfunction

reg[5:0]glyph;reg[4:0]row,col;
reg[23:0]background,foreground;
always @*begin
 glyph=0;row=0;col=0;background=rgb_in;foreground=24'hffffff;
 if(frame_state==1)begin
  if(y<48)begin
   background=24'hef9f27;foreground=24'h412402;
   if(y>=8&&y<40)begin
    row=y-8;col=x;
    if(x>=32&&x<160)begin glyph=text_glyph(0,(x-32)>>5);col=x-32;end
    if(x>=320&&x<416)begin glyph=text_glyph(7,(x-320)>>5);col=x-320;end
    if(x>=480&&x<544)begin glyph=1+(x<512?tens:ones[3:0]);col=x-480;end
    if(x>=544&&x<576)begin glyph=37;col=x-544;end
   end
  end else if(warn_flash&&(x<2||x>=638||y>=478))background=24'hef9f27;
 end
 if(frame_state>=2)begin
  if(frame_state==2)begin
   background=emerg_flash?24'hc62828:24'hb52424;
   if(y<48)background=24'h8e1b1b;
   if(y>=416)begin background=24'hffcdd2;foreground=24'h8e1b1b;end
  end else begin
   background=24'h2e7d32;
   if(y<48)background=24'h1b5e20;
   if(y>=416)background=24'h1b5e20;
  end
  if(x>=192&&x<448&&y>=144&&y<208)begin
   glyph=text_glyph(frame_state==2?1:4,(x-192)>>6);col=(x-192)>>1;row=(y-144)>>1;
  end
  if(y>=240&&y<272)begin
   if(frame_state==2&&x>=208&&x<432)begin glyph=text_glyph(2,(x-208)>>5);col=x-208;row=y-240;end
   if(frame_state==3&&x>=256&&x<384)begin glyph=text_glyph(5,(x-256)>>5);col=x-256;row=y-240;end
  end
  if(x>=272&&x<368&&y>=288&&y<320&&frame_state==2)begin glyph=text_glyph(7,(x-272)>>5);col=x-272;row=y-288;end
  if(x>=256&&x<384&&y>=320&&y<384)begin glyph=1+(x<320?tens:ones[3:0]);col=(x-256)>>1;row=(y-320)>>1;end
  if(frame_state==2&&x>=192&&x<448&&y>=424&&y<456)begin glyph=text_glyph(3,(x-192)>>5);col=x-192;row=y-424;end
  if(frame_state==3&&x>=256&&x<384&&y>=392&&y<424)begin glyph=text_glyph(6,(x-256)>>5);col=x-256;row=y-392;end
 end
end
wire[31:0]font_bits;
`ifdef __ICARUS__
 `ifndef MEDIA60_FONT_PRIMITIVE
  `define MEDIA60_FONT_BEHAVIOR
 `endif
`endif
`ifdef MEDIA60_FONT_BEHAVIOR
reg[31:0]font[0:2047];reg[31:0]font_q;
initial $readmemh("D:/EG4S20/Contest/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/project2/lab_ex4_tf_audio_settings67/src/user_source/hdl_source/emergency/emergency_font.hex",font);
always @(posedge clk)font_q<=font[{glyph,row}];
assign font_bits=font_q;
`undef MEDIA60_FONT_BEHAVIOR
`else
wire[23:0]font_bits24;
assign font_bits={4'd0,font_bits24,4'd0};
EG_LOGIC_BRAM #(.DATA_WIDTH_A(24),.ADDR_WIDTH_A(11),.DATA_DEPTH_A(2048),
 .DATA_WIDTH_B(24),.ADDR_WIDTH_B(11),.DATA_DEPTH_B(2048),.MODE("SP"),
 .REGMODE_A("NOREG"),.IMPLEMENT("9K"),.DEBUGGABLE("NO"),.PACKABLE("NO"),
 .INIT_FILE("D:/EG4S20/Contest/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/project2/lab_ex4_tf_audio_settings67/src/user_source/hdl_source/emergency/emergency_font24.mif"),.FILL_ALL("NONE")) u_font(
 .dia(24'd0),.dib(24'd0),.addra({glyph,row}),.addrb(11'd0),
 .cea(1'b1),.ceb(1'b0),.ocea(1'b0),.oceb(1'b0),.clka(clk),.clkb(1'b0),
 .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(font_bits24),.dob());
`endif
reg[23:0]bg_s1,fg_s1;reg[4:0]col_s1;reg de_s1,vs_s1;
always @(posedge clk or posedge rst)begin
 if(rst)begin bg_s1<=0;fg_s1<=0;col_s1<=0;de_s1<=0;vs_s1<=1;rgb_out<=0;de_out<=0;vs_out<=1;end
 else begin
  bg_s1<=background;fg_s1<=foreground;col_s1<=col;de_s1<=de_in;vs_s1<=vs_in;
  rgb_out<=!de_s1?24'd0:font_bits[31-col_s1]?fg_s1:bg_s1;de_out<=de_s1;vs_out<=vs_s1;
 end
end
endmodule
