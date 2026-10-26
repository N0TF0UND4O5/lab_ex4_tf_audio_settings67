// Two registered stages: brightness/contrast affect only the picture layer.
module player_picture_adjust(
 input clk,rst,input[15:0]config_word,input[23:0]rgb_in,input de_in,vs_in,
 output reg[23:0]rgb_out,output reg de_out,vs_out
);
wire signed[4:0]factor=$signed({2'b00,config_word[9:7]})+5'sd2;
wire signed[9:0]offset=($signed({1'b0,config_word[6:3]})-5'sd4)*10'sd16;
reg signed[12:0]r,g,b;reg signed[9:0]bias;reg de1,vs1;
function[7:0]clip;
 input signed[12:0]value;
 begin clip=value<0?0:value>255?255:value[7:0];end
endfunction
always @(posedge clk or posedge rst)begin
 if(rst)begin r<=0;g<=0;b<=0;bias<=0;de1<=0;vs1<=1;rgb_out<=0;de_out<=0;vs_out<=1;end
 else begin
  r<=($signed({1'b0,rgb_in[23:16]})-9'sd128)*factor;
  g<=($signed({1'b0,rgb_in[15:8]})-9'sd128)*factor;
  b<=($signed({1'b0,rgb_in[7:0]})-9'sd128)*factor;
  bias<=offset;de1<=de_in;vs1<=vs_in;
  rgb_out<={clip((r>>>2)+13'sd128+bias),clip((g>>>2)+13'sd128+bias),clip((b>>>2)+13'sd128+bias)};
  de_out<=de1;vs_out<=vs1;
 end
end
endmodule
