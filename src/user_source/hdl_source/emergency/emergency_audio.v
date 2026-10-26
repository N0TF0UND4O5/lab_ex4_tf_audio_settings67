// Alarm replaces music samples; I2S reception, PCM cadence and ACR stay alive.
// Square-wave warning/siren generated from the same actual PCM sample strobe.
module emergency_audio #(parameter integer SAMPLE_HZ=48028)(
 input clk,rst,input[1:0]state,input valid,input[23:0]left_in,right_in,
 output[23:0]left_out,right_out);
reg[1:0]previous;
reg[15:0]sample_count;
reg[23:0]phase;
wire warning_beep=sample_count<SAMPLE_HZ/8;
wire siren_gate=sample_count<SAMPLE_HZ*3/4;
wire[23:0]step=sample_count<SAMPLE_HZ/2?24'd227060:24'd349323;
wire[23:0]tone=phase[23]?24'hf00000:24'h100000;
assign left_out=state==3?24'd0:state==2?(siren_gate?tone:24'd0):
 state==1&&warning_beep?(phase[23]?24'hf80000:24'h080000):left_in;
assign right_out=state==0||state==1&&!warning_beep?right_in:left_out;
always @(posedge clk or posedge rst)begin
 if(rst)begin previous<=0;sample_count<=0;phase<=0;end
 else if(state!=previous)begin previous<=state;sample_count<=0;phase<=0;end
 else if(valid)begin
  sample_count<=sample_count==SAMPLE_HZ-1?0:sample_count+1'b1;
  phase<=phase+(state==2?step:24'd349323);
 end
end
endmodule
