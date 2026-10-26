// Registered three-cycle OSD pipeline; all video control signals share latency.
// Coordinates count DE pixels, independently of frame-buffer read addressing.
module hdmi_subtitle_osd #(parameter SCROLL_ENABLE=0)(
 input pause_scroll,input scroll_enable,
 input clk,rst,enable,input [23:0]rgb_in,input de_in,vs_in,
 input [2:0]buffer0_image,buffer1_image,input active_buffer,auto_mode_in,image_valid_in,
 input[23:0]buffer0_size,buffer1_size,input[3:0]image_total,
 output reg image_switch,output reg[23:0]rgb_out,output reg de_out,vs_out
);
reg[2:0] b0_s0,b0_s1,b1_s0,b1_s1;
reg[23:0]size0_s0,size0_s1,size1_s0,size1_s1;
reg[3:0]total_s0,total_s1;
// Payload has no validity of its own. Global valid and bank/tag handshakes
// guarantee data is written long before display; resetting these CDC data FFs
// only adds unnecessary global asynchronous-reset routing load.
always @(posedge clk)begin
 size0_s0<=buffer0_size;size0_s1<=size0_s0;size1_s0<=buffer1_size;size1_s1<=size1_s0;
end

reg[1:0]bank_sync,auto_sync,valid_sync;
reg[2:0]frame_image;
reg[3:0]frame_total;
reg frame_auto,frame_valid;
reg[9:0]scroll_offset;
reg subtitle_visible,subtitle_scroll;
always @(posedge clk or posedge rst)begin
 if(rst)begin subtitle_visible<=0;subtitle_scroll<=0;end
 else if(vs_prev&&!vs_in)begin subtitle_visible<=enable;subtitle_scroll<=scroll_enable;end
end
always @(posedge clk or posedge rst)begin
 if(rst)scroll_offset<=0;
 else if(!subtitle_scroll)scroll_offset<=0;
 else if(SCROLL_ENABLE&&subtitle_scroll&&subtitle_visible&&!pause_scroll&&de_in&&!de_prev&&y_count==0)
  scroll_offset<=scroll_offset==815?0:scroll_offset+1'b1;
end
wire signed[11:0]ticker_x=$signed({2'b00,x})-12'sd608+$signed({2'b00,scroll_offset});
reg de_prev,vs_prev;
reg[9:0]x_count,y_count;
wire[9:0]x=de_prev?x_count:10'd0;
wire[9:0]y=y_count;
always @(posedge clk or posedge rst)begin
 if(rst)begin
  b0_s0<=0;b0_s1<=0;b1_s0<=0;b1_s1<=0;bank_sync<=0;auto_sync<=0;valid_sync<=0;
  total_s0<=0;total_s1<=0;frame_total<=0;
  image_switch<=0;frame_image<=0;frame_auto<=0;frame_valid<=0;de_prev<=0;vs_prev<=1;x_count<=0;y_count<=0;
 end else begin
  image_switch<=0;
  total_s0<=image_total;total_s1<=total_s0;
  b0_s0<=buffer0_image;b0_s1<=b0_s0;b1_s0<=buffer1_image;b1_s1<=b1_s0;
  bank_sync<={bank_sync[0],active_buffer};auto_sync<={auto_sync[0],auto_mode_in};valid_sync<={valid_sync[0],image_valid_in};
  de_prev<=de_in;vs_prev<=vs_in;
  if(vs_prev&&!vs_in)y_count<=0;else if(de_prev&&!de_in)y_count<=y_count+1'b1;
  if(de_in)x_count<=x+1'b1;else x_count<=0;
  // First active pixel: the row-zero prefetch has already selected rf_base.
  // Buffer tags were registered before loading and remain stable while displayed.
  if(de_in&&!de_prev&&y_count==0)begin
   image_switch<=valid_sync[1]&&(!frame_valid||frame_image!=(bank_sync[1]?b1_s1:b0_s1));
   frame_image<=bank_sync[1]?b1_s1:b0_s1;frame_total<=total_s1;frame_auto<=auto_sync[1];frame_valid<=valid_sync[1];
  end
 end
end
// 16px text: five characters, three blank cells, seven characters.
function[5:0]subtitle_glyph;input[3:0]index;begin case(index)
0:subtitle_glyph=46;1:subtitle_glyph=47;2:subtitle_glyph=48;
3:subtitle_glyph=49;4:subtitle_glyph=50;
8:subtitle_glyph=51;9:subtitle_glyph=52;10:subtitle_glyph=53;
11:subtitle_glyph=54;12:subtitle_glyph=53;13:subtitle_glyph=55;14:subtitle_glyph=56;
default:subtitle_glyph=0;endcase end endfunction

// Convert the newly selected buffer's real BMP dimensions before label row16.
// One shared 12-bit double-dabble unit,24 cycles/frame; no pixel-path division.
wire[23:0]selected_size=bank_sync[1]?size1_s1:size0_s1;
reg[11:0]binary_value,height_pending;
reg[15:0]bcd_work,width_bcd,height_bcd;
reg[3:0]bcd_count;reg bcd_busy,bcd_height;
reg[15:0]bcd_adjusted;
integer digit;
always @*begin
 bcd_adjusted=bcd_work;
 for(digit=0;digit<4;digit=digit+1)
  if(bcd_work[digit*4+:4]>=5)bcd_adjusted[digit*4+:4]=bcd_work[digit*4+:4]+4'd3;
end
wire[15:0]bcd_next={bcd_adjusted[14:0],binary_value[11]};
always @(posedge clk or posedge rst)begin
 if(rst)begin binary_value<=0;height_pending<=0;bcd_work<=0;width_bcd<=0;height_bcd<=0;bcd_count<=0;bcd_busy<=0;bcd_height<=0;end
 else if(de_in&&!de_prev&&y_count==0)begin
  binary_value<=selected_size[23:12];height_pending<=selected_size[11:0];
  bcd_work<=0;bcd_count<=0;bcd_busy<=1;bcd_height<=0;
 end else if(bcd_busy)begin
  binary_value<={binary_value[10:0],1'b0};bcd_work<=bcd_next;bcd_count<=bcd_count+1'b1;
  if(bcd_count==11)begin
   if(!bcd_height)begin width_bcd<=bcd_next;binary_value<=height_pending;bcd_work<=0;bcd_count<=0;bcd_height<=1;end
   else begin height_bcd<=bcd_next;bcd_busy<=0;end
  end
 end
end
function[5:0]resolution_glyph;
 input[3:0]index;reg[3:0]n;reg visible;
 begin n=0;visible=1;
  case(index)
   0:begin n=width_bcd[15:12];visible=|width_bcd[15:12];end
   1:begin n=width_bcd[11:8];visible=|width_bcd[15:8];end
   2:begin n=width_bcd[7:4];visible=|width_bcd[15:4];end
   3:n=width_bcd[3:0];
   5:begin n=height_bcd[15:12];visible=|height_bcd[15:12];end
   6:begin n=height_bcd[11:8];visible=|height_bcd[15:8];end
   7:begin n=height_bcd[7:4];visible=|height_bcd[15:4];end
   8:n=height_bcd[3:0];
   default:visible=0;
  endcase
  resolution_glyph=index==4?45:visible?35+n:0;
 end
endfunction


reg[5:0]glyph;
reg[3:0]row,col;
reg text_area;
always @* begin
 glyph=0;row=0;col=0;text_area=0;
 if(frame_valid&&y>=16&&y<32&&x>=16&&x<160)begin
  row=y-16;col=x-16;glyph=resolution_glyph((x-16)>>4);text_area=1;
 end else if(subtitle_visible&&y>=362&&y<378)begin
  row=y-10'd362;
  if(SCROLL_ENABLE&&subtitle_scroll)begin
   if(x>=32&&x<608&&ticker_x>=0&&ticker_x<240)begin
    col=ticker_x[3:0];glyph=subtitle_glyph(ticker_x[7:4]);text_area=1;
   end
  end else if(x>=200&&x<440)begin
   col=x-10'd200;glyph=subtitle_glyph((x-10'd200)>>4);text_area=1;
  end
 end
end
reg[23:0]rgb_s1;
reg panel_s1,accent_s1,text_s1,de_s1,vs_s1;
reg[5:0]glyph_s1;
reg[3:0]row_s1,col_s1;
always @(posedge clk or posedge rst)begin
 if(rst)begin rgb_s1<=0;panel_s1<=0;accent_s1<=0;text_s1<=0;de_s1<=0;vs_s1<=1;glyph_s1<=0;row_s1<=0;col_s1<=0;end
 else begin
  rgb_s1<=rgb_in;de_s1<=de_in;vs_s1<=vs_in;
  panel_s1<=de_in&&((subtitle_visible&&x>=16&&x<624&&y>=356&&y<386)||(frame_valid&&x>=8&&x<168&&y>=8&&y<40));
  accent_s1<=0;
  text_s1<=de_in&&text_area;glyph_s1<=glyph;row_s1<=row;col_s1<=col;
 end
end
// Include expanded below by generator: ROM needs no external initialization file.
// 16x16 bitmap glyph rows; row MSB is leftmost pixel.


// Synchronous font lookup permits BRAM inference; delay all metadata equally.
wire[15:0]bits_s2;
`ifdef __ICARUS__
 `ifndef PLAYER52_TEST_PRIMITIVE
  `define PLAYER52_BEHAVIOR_FONT
 `endif
`endif
`ifdef PLAYER52_BEHAVIOR_FONT
reg[15:0]bits_sim;
reg[15:0]subtitle_font[0:1023];
initial $readmemh("settings67_subtitle_font.hex",subtitle_font);
always @(posedge clk)bits_sim<=subtitle_font[{glyph_s1,row_s1}];
assign bits_s2=bits_sim;
`undef PLAYER52_BEHAVIOR_FONT
`else
EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(10),.DATA_DEPTH_A(1024),
 .DATA_WIDTH_B(16),.ADDR_WIDTH_B(10),.DATA_DEPTH_B(1024),.MODE("SP"),
 .REGMODE_A("NOREG"),.IMPLEMENT("9K"),.DEBUGGABLE("NO"),.PACKABLE("NO"),
 .INIT_FILE("D:/EG4S20/Contest/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/project2/lab_ex4_tf_audio_settings67/src/user_source/hdl_source/osd/settings67_subtitle_font.mif"),.FILL_ALL("NONE")) u_subtitle_rom(
 .dia(16'd0),.dib(16'd0),.addra({glyph_s1,row_s1}),.addrb(10'd0),
 .cea(1'b1),.ceb(1'b0),.ocea(1'b0),.oceb(1'b0),.clka(clk),.clkb(1'b0),
 .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(bits_s2),.dob());
`endif
reg[23:0]rgb_s2;reg panel_s2,accent_s2,text_s2,de_s2,vs_s2;reg[3:0]col_s2;
always @(posedge clk or posedge rst)begin
 if(rst)begin rgb_s2<=0;panel_s2<=0;accent_s2<=0;text_s2<=0;de_s2<=0;vs_s2<=1;col_s2<=0;end
 else begin rgb_s2<=rgb_s1;panel_s2<=panel_s1;accent_s2<=accent_s1;text_s2<=text_s1;de_s2<=de_s1;vs_s2<=vs_s1;col_s2<=col_s1;end
end
wire font_pixel=text_s2&&bits_s2[15-col_s2];
wire[23:0]dimmed={1'b0,rgb_s2[23:17],1'b0,rgb_s2[15:9],1'b0,rgb_s2[7:1]};
always @(posedge clk or posedge rst)begin
 if(rst)begin rgb_out<=0;de_out<=0;vs_out<=1;end
 else begin
  de_out<=de_s2;vs_out<=vs_s2;
  rgb_out<=!de_s2?24'd0:font_pixel?24'hffffff:accent_s2?24'hffc040:panel_s2?dimmed:rgb_s2;
 end
end
endmodule
