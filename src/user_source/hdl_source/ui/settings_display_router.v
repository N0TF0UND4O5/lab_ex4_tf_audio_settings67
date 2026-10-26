// SW1 up=HDMI menu, down=TFT menu. All switching commits at VS blanking.
// One renderer/dual-read font serves both mutually exclusive destinations.
module settings_display_router #(parameter integer DEBOUNCE_CYCLES=500000)(
 input clk,rst,sw1,input[25:0]packet,input[23:0]rgb_in,input de_in,vs_in,
 output reg[23:0]rgb_out,output reg de_out,vs_out,output reg hdmi_active,
 inout[15:0]lcd_db,output lcd_cs_n,lcd_rs,lcd_wr_n,lcd_rd_n,lcd_rst_n,lcd_bl,
 output[15:0]chip_id,output ready,fault
);
 localparam CW=DEBOUNCE_CYCLES<2?1:$clog2(DEBOUNCE_CYCLES);
 reg[1:0]switch_sync;
 reg switch_stable;
 reg[CW-1:0]switch_count;
 always @(posedge clk or posedge rst)begin
  if(rst)begin switch_sync<=0;switch_stable<=0;switch_count<=0;end
  else begin
   switch_sync<={switch_sync[0],sw1};
   if(switch_sync[1]==switch_stable)switch_count<=0;
   else if(switch_count==DEBOUNCE_CYCLES-1)begin switch_stable<=switch_sync[1];switch_count<=0;end
   else switch_count<=switch_count+1'b1;
  end
 end
 reg de_prev,vs_prev;
 reg[9:0]x_count,y_count;
 reg[25:0]frame_packet;
 wire[9:0]x=de_prev?x_count:10'd0;
 wire[9:0]y=y_count;
 always @(posedge clk or posedge rst)begin
  if(rst)begin de_prev<=0;vs_prev<=1;x_count<=0;y_count<=0;hdmi_active<=0;frame_packet<=26'h21ce124;end
  else begin
   de_prev<=de_in;vs_prev<=vs_in;
   if(vs_prev&&!vs_in)begin y_count<=0;hdmi_active<=switch_stable;frame_packet<=packet;end
   else if(de_prev&&!de_in)y_count<=y_count+1'b1;
   if(de_in)x_count<=x+1'b1;else x_count<=0;
  end
 end
 // Bottom subtitle footprint: four columns x three rows, 12px glyphs.
 // Translate each label/value cell into the shared TFT renderer coordinates.
 wire panel=hdmi_active&&de_in&&x>=16&&x<624&&y>=392&&y<464;
 reg[7:0]hdmi_x;reg[8:0]hdmi_y;
 reg[9:0]cell_x;reg[3:0]item;reg[1:0]menu_row;
 reg[4:0]cell_y;reg row_active,cell_active;
 always @*begin
  if(x<174)begin cell_x=x-10'd28;item=0;end
  else if(x<320)begin cell_x=x-10'd174;item=3;end
  else if(x<466)begin cell_x=x-10'd320;item=6;end
  else begin cell_x=x-10'd466;item=9;end
  row_active=0;cell_y=0;menu_row=0;
  if(y>=414&&y<426)begin row_active=1;cell_y=y-10'd414;menu_row=0;end
  else if(y>=430&&y<442)begin row_active=1;cell_y=y-10'd430;menu_row=1;end
  else if(y>=446&&y<458)begin row_active=1;cell_y=y-10'd446;menu_row=2;end
  item=item+menu_row;
  cell_active=row_active&&item<11&&((cell_x<60)||(cell_x>=88&&cell_x<136));
  hdmi_x=0;hdmi_y=0;
  if(panel&&cell_active)begin
   hdmi_x=cell_x<60 ? 8'd8+{cell_x[6:0],1'b0}:8'd132+((cell_x-10'd88)<<1);
   hdmi_y=9'd42+{item,4'b0000}+{item,3'b000}+{cell_y,1'b0};
  end
  if(panel&&x>=28&&x<76&&y>=395&&y<407)begin
   hdmi_x=8'd72+((x-10'd28)<<1);hdmi_y=9'd10+((y-10'd395)<<1);
  end
 end
 wire selected=panel&&row_active&&item<11&&item==frame_packet[24:21]&&cell_x<137;
 wire[7:0]tft_x;
 wire[8:0]tft_y;
 wire[25:0]tft_packet;
 wire[15:0]rendered;
 wire tft_bl_raw;
 // Only the TFT peripheral is held at its original reset state while HDMI
 // owns the renderer. Playback and settings control never share this reset.
 wire tft_reset=rst||hdmi_active;
 tft_settings_display u_tft(.clk(clk),.rst(tft_reset),.packet(packet),
  .lcd_db(lcd_db),.lcd_cs_n(lcd_cs_n),.lcd_rs(lcd_rs),.lcd_wr_n(lcd_wr_n),
  .lcd_rd_n(lcd_rd_n),.lcd_rst_n(lcd_rst_n),.lcd_bl(tft_bl_raw),
  .chip_id(chip_id),.ready(ready),.fault(fault),.render_pixel(rendered),
  .render_x(tft_x),.render_y(tft_y),.render_packet(tft_packet));
 assign lcd_bl=!hdmi_active&&tft_bl_raw;
 tft_settings_renderer u_renderer(.clk(clk),.x(hdmi_active?hdmi_x:tft_x),
  .y(hdmi_active?hdmi_y:tft_y),.packet(hdmi_active?frame_packet:tft_packet),
  .small_text(hdmi_active),.rgb565(rendered));

 // Font latency3 + registered blend1. RGB,DE,VS and region flags align.
 reg[23:0]rgb1,rgb2,rgb3;
 reg[2:0]de_pipe,vs_pipe,panel_pipe,border_pipe,selected_pipe;
 wire border=panel&&x<20;
 wire[23:0]dimmed={1'b0,rgb3[23:17],1'b0,rgb3[15:9],1'b0,rgb3[7:1]};
 wire[7:0]selected_r={1'b0,rgb3[23:17]}+8'd16;
 wire[7:0]selected_g={1'b0,rgb3[15:9]}+8'd24;
 wire[7:0]selected_b={1'b0,rgb3[7:1]}+8'd48;
 wire[23:0]selected_blend={selected_r,selected_g,selected_b};
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   rgb1<=0;rgb2<=0;rgb3<=0;de_pipe<=0;vs_pipe<=7;panel_pipe<=0;border_pipe<=0;selected_pipe<=0;
   rgb_out<=0;de_out<=0;vs_out<=1;
  end else begin
   rgb1<=rgb_in;rgb2<=rgb1;rgb3<=rgb2;
   de_pipe<={de_pipe[1:0],de_in};vs_pipe<={vs_pipe[1:0],vs_in};
   panel_pipe<={panel_pipe[1:0],panel};border_pipe<={border_pipe[1:0],border};selected_pipe<={selected_pipe[1:0],selected};
   de_out<=de_pipe[2];vs_out<=vs_pipe[2];
   rgb_out<=!de_pipe[2]?24'd0:!panel_pipe[2]?rgb3:
    rendered==16'hffff ? 24'hffffff:border_pipe[2]?24'h80c8ff:
    selected_pipe[2] ? selected_blend:dimmed;
  end
 end
endmodule
