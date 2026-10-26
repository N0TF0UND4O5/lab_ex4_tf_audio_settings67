// Sequential restoring divider: geometry only, no divider in the pixel path.
module scaler_geometry_divider(input clk,rst,start,input[20:0]numerator,input[15:0]denominator,
 output reg valid,output reg[20:0]quotient,output reg[15:0]remainder);
reg busy;reg[20:0]dividend,q;reg[11:0]den,rem;reg[4:0]count;
wire[12:0]trial={rem,dividend[20]};wire take=trial>={1'b0,den};
wire[11:0]nr=take?trial-den:trial;wire[20:0]nq={q[19:0],take};
always @(posedge clk or posedge rst)begin
 if(rst)begin busy<=0;valid<=0;quotient<=0;remainder<=0;dividend<=0;q<=0;den<=1;rem<=0;count<=0;end
 else begin
  valid<=0;
  if(start)begin busy<=1;dividend<=numerator;q<=0;den<=denominator==0?1:denominator;rem<=0;count<=20;end
  else if(busy)begin dividend<={dividend[19:0],1'b0};q<=nq;rem<=nr;
   if(count==0)begin quotient<=nq;remainder<=nr;valid<=1;busy<=0;end else count<=count-1'b1;
  end
 end
end
endmodule

// Stream file-order rows -> fixed output raster. Preserve aspect ratio, black bars.
// Q8 align-corners coordinates with exact remainder stepping; shared channel arithmetic.
// 16-entry elastic input queue absorbs parser/sector backpressure latency.
module bmp_bilinear_scaler #(parameter OUT_WIDTH=640,OUT_HEIGHT=480,MAX_WIDTH=2048,KEEP_ASPECT=1)(
 input clk,rst,start,input[15:0]source_width,source_height,
 input in_valid,input[23:0]in_rgb,output in_ready,
 output out_valid,output[31:0]out_data,input out_ready,
 output reg busy,done,fault
);
localparam WAIT_ROWS=0,READ0=1,READ1=2,HORIZONTAL=3,VERTICAL=4,EMIT=5,
 VIEW_WAIT=6,X_REQUEST=7,X_WAIT=8,Y_REQUEST=9,Y_WAIT=10,DRAIN=11,IDLE=12,H0_DIFF=13,H0_MULT=14,H0_ADD=15,H1_FETCH=16,H1_DIFF=17,H1_MULT=18,H1_ADD=19,V_MULT=20,V_SUM=21,V_STORE=22,GEOM_MULT=23,GEOM_SELECT=24,COORD_PREP=25,COORD_FLAGS=26,COORD_ADVANCE=27,ROW_TARGET=28,GEOM_VALIDATE=29;
reg[4:0]state;reg[11:0]sw,sh;reg[9:0]vw,vh,left_pad,top_pad;
reg fit_width;reg geometry_ready;reg request_prev;
reg[20:0]width_product,height_product;
reg[15:0]pending_width,pending_height;
reg div_start;reg[20:0]div_num;reg[15:0]div_den;
wire div_valid;wire[20:0]div_q;wire[15:0]div_r;
scaler_geometry_divider geo(clk,rst,div_start,div_num,div_den,div_valid,div_q,div_r);
reg[23:0]queue[0:15];reg[3:0]wp,rp;reg[4:0]used;
reg[10:0]sx;reg[11:0]received_rows;
reg[9:0]dx,dy;reg[18:0]xpos,ypos,xstep,ystep;reg[9:0]xrem,yrem,xerr,yerr;
wire[9:0]right_edge=left_pad+vw,bottom_edge=top_pad+vh;
wire active=(dx>=left_pad&&dx<right_edge&&dy>=top_pad&&dy<bottom_edge);
wire[11:0]sw_last=sw-12'd1,sh_last=sh-12'd1;
wire[9:0]vw_last=vw-10'd1,vh_last=vh-10'd1;
wire[18:0]x_endpoint={sw_last[10:0],8'd0},y_endpoint={sh_last[10:0],8'd0};
wire[18:0]x_center={1'b0,sw_last[10:0],7'd0},y_center={1'b0,sh_last[10:0],7'd0};
wire[11:0]x0={1'b0,xpos[18:8]};wire[11:0]x1=x0<sw_last?x0+12'd1:x0;
wire[11:0]y0={1'b0,ypos[18:8]};wire[11:0]y1=y0<sh_last?y0+12'd1:y0;
reg[11:0]target_y1;reg pixel_active;
reg[10:0]target_x0,target_x1;
// Clamp the second source-row index before deciding row-RAM writes. Otherwise
// subtract->clamp->row-count compare cascades into the BRAM write enable.
wire pop=geometry_ready&&used!=0&&
 ((state==WAIT_ROWS&&pixel_active&&received_rows<=target_y1)||(state==DRAIN&&received_rows<sh));
// Once the complete image is consumed, let the parser drain sector padding/trailer.
assign in_ready=!busy||(geometry_ready&&used<8);
wire push=in_valid&&busy; // upstream valid may arrive a few cycles after ready falls
reg[23:0]row0[0:MAX_WIDTH-1]; /* fehdl force_ram=1, ram_style="bram" */
reg[23:0]row1[0:MAX_WIDTH-1]; /* fehdl force_ram=1, ram_style="bram" */
reg[23:0]qrow0,qrow1,lrow0,lrow1;
wire[10:0]read_x=state==READ0?target_x0:target_x1;
always @(posedge clk)begin
 if(pop)begin if(received_rows[0])row1[sx]<=queue[rp];else row0[sx]<=queue[rp];end
 if(state==READ0||state==READ1)begin qrow0<=row0[read_x];qrow1<=row1[read_x];end
end
wire[23:0]a0=y0[0]?lrow1:lrow0,a1=y1[0]?lrow1:lrow0;
wire[23:0]b0=y0[0]?qrow1:qrow0,b1=y1[0]?qrow1:qrow0;
// The multiply path is time-shared by both axes and all three channels. Scaling runs
// while the previous image is displayed, so ~40 cycles/output pixel is sufficient.
function[7:0]channel;input[23:0]rgb;input[1:0]index;begin case(index)
 0:channel=rgb[23:16];1:channel=rgb[15:8];default:channel=rgb[7:0];endcase end endfunction
reg[1:0]component;
wire[7:0]al=channel(a0,component),ar=channel(b0,component),bl=channel(a1,component),br=channel(b1,component);
reg[7:0]left_sample,right_sample;
reg signed[17:0]hleft,hright,delta_registered;
reg signed[8:0]fraction_registered;
reg signed[26:0]product;
wire signed[26:0]vertical_sum=(hleft<<<8)+product;
reg[23:0]vertical_partial;
wire[24:0]rounded={1'b0,vertical_partial}+25'd32768;
reg[23:0]pixel_rgb;reg blank_pixel;
assign out_valid=state==EMIT;
assign out_data=blank_pixel?32'd0:{pixel_rgb,8'd0};
reg[10:0]xe_sum,ye_sum;
reg[18:0]xpos_step,ypos_step;
reg[9:0]next_xerr,next_yerr;
reg xcarry,ycarry,end_column,end_frame,x_advance,y_advance,last_active_x,last_active_y;
always @(posedge clk or posedge rst)begin
 if(rst)begin
  state<=IDLE;busy<=0;done<=0;fault<=0;request_prev<=0;geometry_ready<=0;
  sw<=1;sh<=1;vw<=OUT_WIDTH;vh<=OUT_HEIGHT;left_pad<=0;top_pad<=0;fit_width<=0;width_product<=0;height_product<=0;
  pending_width<=0;pending_height<=0;
  div_start<=0;div_num<=0;div_den<=1;wp<=0;rp<=0;used<=0;sx<=0;received_rows<=0;
  dx<=0;dy<=0;xpos<=0;ypos<=0;xstep<=0;ystep<=0;xrem<=0;yrem<=0;xerr<=0;yerr<=0;
  xe_sum<=0;ye_sum<=0;xpos_step<=0;ypos_step<=0;next_xerr<=0;next_yerr<=0;
  target_y1<=0;pixel_active<=0;target_x0<=0;target_x1<=0;
  xcarry<=0;ycarry<=0;end_column<=0;end_frame<=0;x_advance<=0;y_advance<=0;last_active_x<=0;last_active_y<=0;
  lrow0<=0;lrow1<=0;component<=0;hleft<=0;hright<=0;delta_registered<=0;fraction_registered<=0;left_sample<=0;right_sample<=0;vertical_partial<=0;product<=0;pixel_rgb<=0;blank_pixel<=0;
 end else begin
  request_prev<=start;div_start<=0;done<=0;
  if(start&&!request_prev)begin
   busy<=1;fault<=0;geometry_ready<=0;pending_width<=source_width;pending_height<=source_height;
   wp<=0;rp<=0;used<=0;sx<=0;received_rows<=0;dx<=0;dy<=0;xerr<=0;yerr<=0;
   state<=GEOM_VALIDATE;
  end else begin
   if(push)begin
    if(used==16&&!pop)fault<=1;
    else begin queue[wp]<=in_rgb;wp<=wp+1'b1;end
   end
   if(pop)begin
    rp<=rp+1'b1;
    if(sx==sw_last)begin sx<=0;received_rows<=received_rows+1'b1;end else sx<=sx+1'b1;
   end
   case({push,pop})2'b10:if(used<16)used<=used+1'b1;2'b01:used<=used-1'b1;default:;endcase
   case(state)
    GEOM_VALIDATE:begin
     if(pending_width==0||pending_width>MAX_WIDTH||pending_height==0||pending_height>2048)begin fault<=1;busy<=0;state<=IDLE;end
     else begin
      sw<=pending_width[11:0];sh<=pending_height[11:0];
      if(!KEEP_ASPECT)begin vw<=OUT_WIDTH;vh<=OUT_HEIGHT;state<=X_REQUEST;end
      else state<=GEOM_MULT;
     end
    end
    // Latch dimensions before multiplying. Compare registered products on a
    // separate edge: header absolute-height conversion must not cascade into
    // the aspect-ratio multiplier/comparator at the 100 MHz SD clock.
    GEOM_MULT:begin width_product<=sw*OUT_HEIGHT;height_product<=sh*OUT_WIDTH;state<=GEOM_SELECT;end
    GEOM_SELECT:begin
     fit_width<=width_product>=height_product;div_start<=1;
     if(width_product>=height_product)begin vw<=OUT_WIDTH;div_num<=height_product;div_den<=sw;end
     else begin vh<=OUT_HEIGHT;div_num<=width_product;div_den<=sh;end
     state<=VIEW_WAIT;
    end
    VIEW_WAIT:if(div_valid)begin
     if(fit_width)vh<=div_q==0?1:div_q;else vw<=div_q==0?1:div_q;
     state<=X_REQUEST;
    end
    X_REQUEST:begin
     left_pad<=(OUT_WIDTH-vw)>>1;top_pad<=(OUT_HEIGHT-vh)>>1;
     div_num<=vw>1?{2'd0,x_endpoint}:21'd0;div_den<=vw>1?{6'd0,vw_last}:16'd1;div_start<=1;
     xpos<=vw>1?19'd0:x_center;state<=X_WAIT;
    end
    X_WAIT:if(div_valid)begin xstep<=div_q;xrem<=div_r;state<=Y_REQUEST;end
    Y_REQUEST:begin div_num<=vh>1?{2'd0,y_endpoint}:21'd0;div_den<=vh>1?{6'd0,vh_last}:16'd1;div_start<=1;ypos<=vh>1?19'd0:y_center;state<=Y_WAIT;end
    Y_WAIT:if(div_valid)begin ystep<=div_q;yrem<=div_r;geometry_ready<=1;state<=ROW_TARGET;end
    ROW_TARGET:begin target_y1<=y1;target_x0<=x0[10:0];target_x1<=x1[10:0];pixel_active<=active;state<=WAIT_ROWS;end
    WAIT_ROWS:begin
     if(!pixel_active)begin blank_pixel<=1;state<=EMIT;end
     else if(received_rows>target_y1)begin blank_pixel<=0;component<=0;state<=READ0;end
    end
    READ0:state<=READ1;
    READ1:begin lrow0<=qrow0;lrow1<=qrow1;state<=HORIZONTAL;end
    HORIZONTAL:begin left_sample<=al;right_sample<=ar;fraction_registered<=$signed({1'b0,xpos[7:0]});state<=H0_DIFF;end
    H0_DIFF:begin delta_registered<=$signed({1'b0,right_sample})-$signed({1'b0,left_sample});state<=H0_MULT;end
    H0_MULT:begin product<=delta_registered*fraction_registered;state<=H0_ADD;end
    H0_ADD:begin hleft<=$signed({1'b0,left_sample,8'd0})+product;state<=H1_FETCH;end
    H1_FETCH:begin left_sample<=bl;right_sample<=br;fraction_registered<=$signed({1'b0,xpos[7:0]});state<=H1_DIFF;end
    H1_DIFF:begin delta_registered<=$signed({1'b0,right_sample})-$signed({1'b0,left_sample});state<=H1_MULT;end
    H1_MULT:begin product<=delta_registered*fraction_registered;state<=H1_ADD;end
    H1_ADD:begin hright<=$signed({1'b0,left_sample,8'd0})+product;state<=VERTICAL;end
    VERTICAL:begin delta_registered<=hright-hleft;fraction_registered<=$signed({1'b0,ypos[7:0]});state<=V_MULT;end
    V_MULT:begin product<=delta_registered*fraction_registered;state<=V_SUM;end
    V_SUM:begin vertical_partial<=vertical_sum[23:0];state<=V_STORE;end
    V_STORE:begin
     case(component)0:pixel_rgb[23:16]<=rounded[23:16];1:pixel_rgb[15:8]<=rounded[23:16];2:pixel_rgb[7:0]<=rounded[23:16];endcase
     if(component==2)state<=EMIT;else begin component<=component+1'b1;state<=HORIZONTAL;end
    end
    EMIT:if(out_ready)state<=COORD_PREP;
    COORD_PREP:begin
     xe_sum<={1'b0,xerr}+{1'b0,xrem};ye_sum<={1'b0,yerr}+{1'b0,yrem};
     xpos_step<=xpos+xstep;ypos_step<=ypos+ystep;state<=COORD_FLAGS;
    end
    COORD_FLAGS:begin
     xcarry<=xe_sum>={1'b0,vw_last};ycarry<=ye_sum>={1'b0,vh_last};
     next_xerr<=xe_sum>={1'b0,vw_last}?xe_sum-{1'b0,vw_last}:xe_sum[9:0];
     next_yerr<=ye_sum>={1'b0,vh_last}?ye_sum-{1'b0,vh_last}:ye_sum[9:0];
     end_column<=dx==OUT_WIDTH-1;end_frame<=dy==OUT_HEIGHT-1;
     x_advance<=active&&dx<right_edge-10'd1;y_advance<=dy>=top_pad&&dy<bottom_edge-10'd1;
     last_active_x<=dx==right_edge-10'd2;last_active_y<=dy==bottom_edge-10'd2;
     state<=COORD_ADVANCE;
    end
    COORD_ADVANCE:begin
     if(end_column)begin
      dx<=0;xpos<=vw>1?19'd0:x_center;xerr<=0;
      if(y_advance)begin
       ypos<=last_active_y?y_endpoint:ypos_step+{{18{1'b0}},ycarry};yerr<=next_yerr;
      end
      if(end_frame)state<=DRAIN;else begin dy<=dy+1'b1;state<=ROW_TARGET;end
     end else begin
      dx<=dx+1'b1;
      if(x_advance)begin
       xpos<=last_active_x?x_endpoint:xpos_step+{{18{1'b0}},xcarry};xerr<=next_xerr;
      end
      state<=ROW_TARGET;
     end
    end
    DRAIN:if(received_rows==sh&&used==0)begin busy<=0;done<=1;state<=IDLE;end
    default:;
   endcase
  end
 end
end
endmodule
