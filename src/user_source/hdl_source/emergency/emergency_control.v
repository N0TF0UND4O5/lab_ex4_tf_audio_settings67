module emergency_control #(parameter integer CLOCK_HZ=25000000)(
 input clk,rst,input local_clear,input[9:0]source_command,input source_request,
 output reg acknowledge,output reg[1:0]state,output reg[7:0]seconds,
 output blink_warning,blink_emergency);
localparam CW=$clog2(CLOCK_HZ+1);
reg[CW-1:0]count;
reg[2:0]request_sync;
assign blink_warning=count<CLOCK_HZ/2;
assign blink_emergency=(count<CLOCK_HZ/4)||(count>=CLOCK_HZ/2&&count<CLOCK_HZ*3/4);
always @(posedge clk or posedge rst)begin
 if(rst)begin count<=0;request_sync<=0;acknowledge<=0;state<=0;seconds<=0;end
 else begin
  request_sync<={request_sync[1:0],source_request};
  if(request_sync[2]!=acknowledge)begin
   acknowledge<=request_sync[2];state<=source_command[9:8];
   seconds<=source_command[9:8]==0?0:source_command[7:0];count<=0;
   if(source_command[7:0]==0)begin
    if(source_command[9:8]==1)begin state<=2;seconds<=0;end
    if(source_command[9:8]==3)begin state<=0;seconds<=0;end
   end
  end else if(local_clear&&(state==1||state==2))begin state<=3;seconds<=5;count<=0;
  end else if(count==CLOCK_HZ-1)begin
   count<=0;
   if(seconds!=0)begin
    seconds<=seconds-1'b1;
    if(seconds==1)begin
     if(state==1)state<=2; // Warning expires into latched emergency.
     if(state==3)state<=0; // Clear expires into normal playback.
    end
   end
  end else count<=count+1'b1;
 end
end
endmodule
