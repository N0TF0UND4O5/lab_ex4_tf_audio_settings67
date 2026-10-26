`timescale 1ns/1ps
module tb_bmp67 #(parameter DIRECT=1,STALL=0);
reg clk=0,rst=1;always #5 clk=~clk;
reg[4:0]stall_counter=0;always @(posedge clk)stall_counter<=stall_counter+1'b1;
wire stream_ready=!STALL||stall_counter[2:0]<5;
reg start=0;reg[31:0]w=7,h=3,flen=126;reg[7:0]sddata=0;reg sdvalid=0,sdend=0;
wire req0,req1,wr0,wr1,ready0,ready1;wire[31:0]addr0,addr1;wire[23:0]data0,data1;
bmp_read_reference #(.FLEXIBLE_BMP(1)) b0(.clk(clk),.rst(rst),.pixel_ready(stream_ready),.direct_width(w),.direct_height(h),
 .scan_start(1'b0),.scan_start_sector(32'd0),.scan_max_sector(32'd1024),.scan_target_count(4'd1),
 .load_start(start),.load_abort(1'b0),.load_sector(32'd0),.load_direct(1'(DIRECT)),.direct_file_len(flen),.direct_pixel_offset(32'd54),
 .sd_init_done(1'b1),.bmp_width(16'd640),.bmp_height(16'd480),.write_req_ack(1'b1),
 .sd_sec_read(req0),.sd_sec_read_addr(addr0),.sd_sec_read_data(sddata),.sd_sec_read_data_valid(sdvalid),.sd_sec_read_end(sdend),
 .ready(ready0),.bmp_data_wr_en(wr0),.bmp_data(data0));
bmp_read #(.FLEXIBLE_BMP(1)) b1(.clk(clk),.rst(rst),.pixel_ready(stream_ready),.direct_width(w),.direct_height(h),
 .scan_start(1'b0),.scan_start_sector(32'd0),.scan_max_sector(32'd1024),.scan_target_count(4'd1),
 .load_start(start),.load_abort(1'b0),.load_sector(32'd0),.load_direct(1'(DIRECT)),.direct_file_len(flen),.direct_pixel_offset(32'd54),
 .sd_init_done(1'b1),.bmp_width(16'd640),.bmp_height(16'd480),.write_req_ack(1'b1),
 .sd_sec_read(req1),.sd_sec_read_addr(addr1),.sd_sec_read_data(sddata),.sd_sec_read_data_valid(sdvalid),.sd_sec_read_end(sdend),
 .ready(ready1),.bmp_data_wr_en(wr1),.bmp_data(data1));
integer n0=0,n1=0,offset,pos=0,left=0,sectors=0;reg busy=0;reg delayed_wr=0;reg[23:0]delayed_data=0;
function[7:0]stream_byte;input integer x;integer q,row,withinrow,stride;begin
 stride=(w*3+3)&32'hfffffffc;
 if(x<54)begin
 stream_byte=0;
 case(x)
  0:stream_byte=8'h42;1:stream_byte=8'h4d;
  2,3,4,5:stream_byte=flen>>((x-2)*8);
  10:stream_byte=54;14:stream_byte=40;
  18,19,20,21:stream_byte=w>>((x-18)*8);
  22,23,24,25:stream_byte=h>>((x-22)*8);
  26:stream_byte=1;28:stream_byte=24;
 endcase
end else if(x>=flen)stream_byte=0;
 else begin q=x-54;row=q/stride;withinrow=q%stride;
  if(withinrow>=w*3)stream_byte=8'hde;
  else stream_byte=(row*w*3+withinrow)*7+3;
 end
end endfunction
always @(negedge clk)begin
 if(!rst)begin
  if(req0!==req1||addr0!==addr1||ready0!==ready1)$fatal(1,"control path changed");
  if(wr1!==wr0)$fatal(1,"same-cycle valid mismatch");
  if(wr1 && data1!==data0)$fatal(1,"pixel data mismatch got%h exp%h",data1,data0);
  delayed_wr=wr0;delayed_data=data0;
  if(wr0)begin
 if(data0!=={8'((n0*3+2)*7+3),8'((n0*3+1)*7+3),8'(n0*3*7+3)})$fatal(1,"independent pixel pattern mismatch at%d got%h",n0,data0);
 n0=n0+1;end if(wr1)n1=n1+1;
 end else begin delayed_wr=0;delayed_data=0;end
 // Behavioral sector reader. Only rising requests matter until read-end.
 sdvalid=0;sdend=0;
 if(!busy && req0)begin busy=1;pos=0;offset=addr0*512;left=4;sectors=sectors+1;end
 else if(busy)begin
  if(left>0)left=left-1;
  else if(pos<512)begin sddata=stream_byte(offset+pos);sdvalid=1;pos=pos+1;end
  else begin sdend=1;busy=0;end
 end
end
task run;input integer width,height;begin
 rst=1;start=0;busy=0;n0=0;n1=0;w=width;h=height;flen=54+(((width*3+3)&32'hfffffffc)*height);
 repeat(8)@(posedge clk);#1;rst=0;
 repeat(5)@(posedge clk);#1;start=1;@(posedge clk);#1;start=0;
 wait(!ready0);wait(ready0);repeat(8)@(posedge clk);
 if(n0!=width*height||n1!=n0)$fatal(1,"pixel count %d/%d expected%d",n0,n1,width*height);
 $display("PASS BMP %dx%d pixels%d output identical, same-cycle synchronous-cache prefetch, control timing unchanged",width,height,n1);
end endtask
initial begin run(7,3);run(8,3);run(320,240);if(DIRECT)run(480,800);$finish;end
initial begin #100000000;$fatal(1,"timeout state%d count%d",b0.state,n0);end
endmodule

