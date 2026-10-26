// Spectrum snapshot is atomic and held for one whole video frame.
// Analysis and this compositor share pixel_clk; RGB/DE/VS delay together 1 cycle.
module hdmi_spectrum_overlay(
 input clk,rst,enable,input [23:0]rgb_in,input de_in,vs_in,
 input [511:0]levels,input fault,
 output reg [23:0]rgb_out,output reg de_out,vs_out
);
reg de_prev,vs_prev;
reg [9:0]x_count,y_count;
reg[6:0]frame_levels[0:63];
reg frame_fault;
reg[6:0]peaks[0:63];
reg [4:0]peak_hold[0:63];
integer i;
wire [9:0]x=de_prev?x_count:10'd0;
wire [9:0]y=y_count;
wire [9:0]bar_x=x-10'd64;
wire [5:0]band=bar_x[8:3];
wire[6:0]height=frame_levels[band];
wire[6:0]peak_height=peaks[band];
wire peak_line=x>=64&&x<576&&bar_x[2:0]<6&&peak_height!=0&&y==360-peak_height;
wire panel=enable&&de_in&&x>=32&&x<608&&y>=264&&y<377;
wire bar=panel&&x>=64&&x<576&&bar_x[2:0]<6&&y<360&&y>=280&&y>=360-height;
wire grid=x>=64&&x<576&&(y==280||y==300||y==320||y==340||y==360);
wire accent=y<267;
wire [23:0]dim={1'b0,rgb_in[23:17],1'b0,rgb_in[15:9],1'b0,rgb_in[7:1]};
wire [23:0]color=(y<304)?24'hffb040:(y<332)?24'h40e0b0:24'h40a0ff;
always @(posedge clk or posedge rst)begin
 if(rst)begin
  de_prev<=0;vs_prev<=1;x_count<=0;y_count<=0;frame_fault<=0;
  rgb_out<=0;de_out<=0;vs_out<=1;
  for(i=0;i<64;i=i+1)begin frame_levels[i]<=0;peaks[i]<=0;peak_hold[i]<=0;end
 end else begin
  de_prev<=de_in;vs_prev<=vs_in;
  if(vs_prev&&!vs_in)y_count<=0;else if(de_prev&&!de_in)y_count<=y_count+1'b1;
  if(de_in)x_count<=x+1'b1;else x_count<=0;
  if(de_in&&!de_prev&&y_count==0)begin
   frame_fault<=fault;
   for(i=0;i<64;i=i+1)begin
    frame_levels[i]<=levels[i*8+:7];
    if(levels[i*8+:7]>=peaks[i])begin peaks[i]<=levels[i*8+:7];peak_hold[i]<=18;end
    else if(peak_hold[i]!=0)peak_hold[i]<=peak_hold[i]-1'b1;
    else if(peaks[i]!=0)peaks[i]<=peaks[i]-1'b1;
   end
  end
  de_out<=de_in;vs_out<=vs_in;
  rgb_out<=!panel?rgb_in:accent?(frame_fault?24'hff4040:24'h40c0e0):peak_line?24'hffe8a0:bar?color:grid?24'h506070:dim;
 end
end
endmodule
