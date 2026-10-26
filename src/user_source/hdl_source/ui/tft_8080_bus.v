// 25MHz: setup 80ns, write-low 120ns, hold 80ns; read-low 640ns.
// Tri-state is only at the top-level pad. Input is sampled through two FFs.
module tft_8080_bus(input clk,rst,input request,read_op,rs_in,
 input[15:0]write_data,output idle,output reg done,output reg[15:0]read_data,
 inout[15:0]lcd_db,output reg lcd_cs_n,lcd_rs,lcd_wr_n,lcd_rd_n);
reg[1:0]state;reg[4:0]count;reg reading,drive;reg[15:0]data_out;
reg[15:0]din0,din1;
assign lcd_db=drive?data_out:16'hzzzz;
assign idle=state==0;
always @(posedge clk)begin din0<=lcd_db;din1<=din0;end
always @(posedge clk or posedge rst)begin
 if(rst)begin state<=0;count<=0;reading<=0;drive<=0;data_out<=0;
  lcd_cs_n<=1;lcd_rs<=1;lcd_wr_n<=1;lcd_rd_n<=1;done<=0;read_data<=0;end
 else begin
  done<=0;
  case(state)
   0:if(request)begin
    data_out<=write_data;reading<=read_op;drive<=!read_op;
    lcd_rs<=rs_in;lcd_cs_n<=0;count<=0;state<=1;
   end
   1:if(count==1)begin
    count<=0;lcd_rd_n<=!reading;lcd_wr_n<=reading;state<=2;
   end else count<=count+1'b1;
   2:if(count==(reading?15:2))begin
    if(reading)read_data<=din1;
    lcd_rd_n<=1;lcd_wr_n<=1;count<=0;state<=3;
   end else count<=count+1'b1;
   3:if(count==1)begin
    lcd_cs_n<=1;drive<=0;done<=1;state<=0;
   end else count<=count+1'b1;
  endcase
 end
end
endmodule
