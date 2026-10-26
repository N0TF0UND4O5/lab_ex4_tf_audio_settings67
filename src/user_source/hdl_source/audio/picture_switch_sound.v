module picture_switch_sound(input clk,rst,enable,trigger,valid,
 input[23:0]left_in,right_in,output[23:0]left_out,right_out);
reg pending;reg[12:0]remaining;reg[5:0]tone;
wire[5:0]level=remaining[12:7];
wire signed[23:0]amplitude=$signed({1'b0,level,17'd0})>>>4;
wire signed[23:0]sound=tone[5]?-amplitude:amplitude;
function[23:0]mix;input signed[23:0]a,b;reg signed[24:0]sum;begin
 sum={a[23],a}+{b[23],b};
 mix=sum > 25'sd8388607 ? 24'h7fffff : sum < -25'sd8388608 ? 24'h800000 : sum[23:0];
end endfunction
assign left_out=enable&&remaining!=0?mix(left_in,sound):left_in;
assign right_out=enable&&remaining!=0?mix(right_in,sound):right_in;
always @(posedge clk or posedge rst)begin
 if(rst)begin pending<=0;remaining<=0;tone<=0;end
 else begin
  if(trigger&&enable)pending<=1;
  if(!enable)begin pending<=0;remaining<=0;tone<=0;end
  else if(valid)begin
   if(pending||trigger)begin pending<=0;remaining<=13'd5760;tone<=0;end
   else if(remaining!=0)begin remaining<=remaining-1'b1;tone<=tone+1'b1;end
  end
 end
end
endmodule
