// Gain changes by 1/256 per PCM sample (~5.3ms full-scale ramp).
// Keep valid cadence and ACR alive while muted; analyze exactly this HDMI PCM.
module player_audio_volume(
 input clk,rst,input[3:0]volume,input sound_on,
 input valid_in,input[23:0]left_in,right_in,
 output reg valid_out,output reg[23:0]left_out,right_out
);
wire[8:0]target=sound_on?{volume,5'b00000}:9'd0;
reg[8:0]gain;
wire[8:0]next_gain=gain<target?gain+1'b1:gain>target?gain-1'b1:gain;
reg signed[33:0]lp,rp;reg v1;
always @(posedge clk or posedge rst)begin
 if(rst)begin gain<=256;lp<=0;rp<=0;v1<=0;valid_out<=0;left_out<=0;right_out<=0;end
 else begin
  v1<=valid_in;valid_out<=v1;
  if(valid_in)begin
   gain<=next_gain;
   lp<=$signed(left_in)*$signed({1'b0,next_gain});rp<=$signed(right_in)*$signed({1'b0,next_gain});
  end
  left_out<=lp>>>8;right_out<=rp>>>8;
 end
end
endmodule
