// No FPGA frame buffer: stream RGB565 into the module's internal GRAM.
// Manufacturer ID sequence D3/04; refuse unknown IDs, backlight remains off.
module tft_settings_display_reference #(parameter integer WAIT_20MS=500000,
 parameter integer WAIT_120MS=3000000)(input clk,rst,input[25:0]packet,
 inout[15:0]lcd_db,output lcd_cs_n,lcd_rs,lcd_wr_n,lcd_rd_n,
 output reg lcd_rst_n,lcd_bl,output reg[15:0]chip_id,
 output reg ready,fault);
function[17:0]init_word;input st7789;input[7:0]addr;begin
if(st7789)case(addr)
8'd0:init_word=18'h00011;
8'd1:init_word=18'h20078;
8'd2:init_word=18'h00036;
8'd3:init_word=18'h10000;
8'd4:init_word=18'h0003a;
8'd5:init_word=18'h10005;
8'd6:init_word=18'h000b2;
8'd7:init_word=18'h1000c;
8'd8:init_word=18'h1000c;
8'd9:init_word=18'h10000;
8'd10:init_word=18'h10033;
8'd11:init_word=18'h10033;
8'd12:init_word=18'h000b7;
8'd13:init_word=18'h10035;
8'd14:init_word=18'h000bb;
8'd15:init_word=18'h10032;
8'd16:init_word=18'h000c0;
8'd17:init_word=18'h1000c;
8'd18:init_word=18'h000c2;
8'd19:init_word=18'h10001;
8'd20:init_word=18'h000c3;
8'd21:init_word=18'h10010;
8'd22:init_word=18'h000c4;
8'd23:init_word=18'h10020;
8'd24:init_word=18'h000c6;
8'd25:init_word=18'h1000f;
8'd26:init_word=18'h000d0;
8'd27:init_word=18'h100a4;
8'd28:init_word=18'h100a1;
8'd29:init_word=18'h000e0;
8'd30:init_word=18'h100d0;
8'd31:init_word=18'h10000;
8'd32:init_word=18'h10002;
8'd33:init_word=18'h10007;
8'd34:init_word=18'h1000a;
8'd35:init_word=18'h10028;
8'd36:init_word=18'h10032;
8'd37:init_word=18'h10044;
8'd38:init_word=18'h10042;
8'd39:init_word=18'h10006;
8'd40:init_word=18'h1000e;
8'd41:init_word=18'h10012;
8'd42:init_word=18'h10014;
8'd43:init_word=18'h10017;
8'd44:init_word=18'h000e1;
8'd45:init_word=18'h100d0;
8'd46:init_word=18'h10000;
8'd47:init_word=18'h10002;
8'd48:init_word=18'h10007;
8'd49:init_word=18'h1000a;
8'd50:init_word=18'h10028;
8'd51:init_word=18'h10031;
8'd52:init_word=18'h10054;
8'd53:init_word=18'h10047;
8'd54:init_word=18'h1000e;
8'd55:init_word=18'h1001c;
8'd56:init_word=18'h10017;
8'd57:init_word=18'h1001b;
8'd58:init_word=18'h1001e;
8'd59:init_word=18'h0002a;
8'd60:init_word=18'h10000;
8'd61:init_word=18'h10000;
8'd62:init_word=18'h10000;
8'd63:init_word=18'h100ef;
8'd64:init_word=18'h0002b;
8'd65:init_word=18'h10000;
8'd66:init_word=18'h10000;
8'd67:init_word=18'h10001;
8'd68:init_word=18'h1003f;
8'd69:init_word=18'h00029;
8'd70:init_word=18'h00036;
8'd71:init_word=18'h10000;
8'd72:init_word=18'h30000;
default:init_word=18'h30000;endcase
else case(addr)
8'd0:init_word=18'h000cf;
8'd1:init_word=18'h10000;
8'd2:init_word=18'h100c1;
8'd3:init_word=18'h10030;
8'd4:init_word=18'h000ed;
8'd5:init_word=18'h10064;
8'd6:init_word=18'h10003;
8'd7:init_word=18'h10012;
8'd8:init_word=18'h10081;
8'd9:init_word=18'h000e8;
8'd10:init_word=18'h10085;
8'd11:init_word=18'h10010;
8'd12:init_word=18'h1007a;
8'd13:init_word=18'h000cb;
8'd14:init_word=18'h10039;
8'd15:init_word=18'h1002c;
8'd16:init_word=18'h10000;
8'd17:init_word=18'h10034;
8'd18:init_word=18'h10002;
8'd19:init_word=18'h000f7;
8'd20:init_word=18'h10020;
8'd21:init_word=18'h000ea;
8'd22:init_word=18'h10000;
8'd23:init_word=18'h10000;
8'd24:init_word=18'h000c0;
8'd25:init_word=18'h1001b;
8'd26:init_word=18'h000c1;
8'd27:init_word=18'h10001;
8'd28:init_word=18'h000c5;
8'd29:init_word=18'h10030;
8'd30:init_word=18'h10030;
8'd31:init_word=18'h000c7;
8'd32:init_word=18'h100b7;
8'd33:init_word=18'h00036;
8'd34:init_word=18'h10048;
8'd35:init_word=18'h0003a;
8'd36:init_word=18'h10055;
8'd37:init_word=18'h000b1;
8'd38:init_word=18'h10000;
8'd39:init_word=18'h1001a;
8'd40:init_word=18'h000b6;
8'd41:init_word=18'h1000a;
8'd42:init_word=18'h100a2;
8'd43:init_word=18'h000f2;
8'd44:init_word=18'h10000;
8'd45:init_word=18'h00026;
8'd46:init_word=18'h10001;
8'd47:init_word=18'h000e0;
8'd48:init_word=18'h1000f;
8'd49:init_word=18'h1002a;
8'd50:init_word=18'h10028;
8'd51:init_word=18'h10008;
8'd52:init_word=18'h1000e;
8'd53:init_word=18'h10008;
8'd54:init_word=18'h10054;
8'd55:init_word=18'h100a9;
8'd56:init_word=18'h10043;
8'd57:init_word=18'h1000a;
8'd58:init_word=18'h1000f;
8'd59:init_word=18'h10000;
8'd60:init_word=18'h10000;
8'd61:init_word=18'h10000;
8'd62:init_word=18'h10000;
8'd63:init_word=18'h000e1;
8'd64:init_word=18'h10000;
8'd65:init_word=18'h10015;
8'd66:init_word=18'h10017;
8'd67:init_word=18'h10007;
8'd68:init_word=18'h10011;
8'd69:init_word=18'h10006;
8'd70:init_word=18'h1002b;
8'd71:init_word=18'h10056;
8'd72:init_word=18'h1003c;
8'd73:init_word=18'h10005;
8'd74:init_word=18'h10010;
8'd75:init_word=18'h1000f;
8'd76:init_word=18'h1003f;
8'd77:init_word=18'h1003f;
8'd78:init_word=18'h1000f;
8'd79:init_word=18'h0002b;
8'd80:init_word=18'h10000;
8'd81:init_word=18'h10000;
8'd82:init_word=18'h10001;
8'd83:init_word=18'h1003f;
8'd84:init_word=18'h0002a;
8'd85:init_word=18'h10000;
8'd86:init_word=18'h10000;
8'd87:init_word=18'h10000;
8'd88:init_word=18'h100ef;
8'd89:init_word=18'h00011;
8'd90:init_word=18'h20064;
8'd91:init_word=18'h00029;
8'd92:init_word=18'h00036;
8'd93:init_word=18'h10000;
8'd94:init_word=18'h30000;
default:init_word=18'h30000;endcase end endfunction

localparam BOOT=0,RESET_LOW=1,RESET_HIGH=2,ID_CMD=3,ID_READ=4,
 ID_CHECK=5,INITIALIZE=6,INIT_DELAY=7,WINDOW=8,PIXEL_WAIT=9,
 PIXEL_SEND=10,WAIT_BUS=11,WAIT_CHANGE=12,FAILED=13;
reg[3:0]state,next_state;reg[21:0]wait_count;
reg request,read_op,rs;reg[15:0]write_data;
wire bus_idle,bus_done;wire[15:0]read_data;
reg id_fallback,st7789;reg[2:0]read_index;reg[7:0]init_index;
reg[3:0]window_index;reg[2:0]pixel_wait;
reg[7:0]x;reg[8:0]y;reg[25:0]snapshot;wire[15:0]pixel;
wire[17:0]init_entry=init_word(st7789,init_index);
tft_8080_bus bus(.clk(clk),.rst(rst),.request(request),.read_op(read_op),
 .rs_in(rs),.write_data(write_data),.idle(bus_idle),.done(bus_done),
 .read_data(read_data),.lcd_db(lcd_db),.lcd_cs_n(lcd_cs_n),.lcd_rs(lcd_rs),
 .lcd_wr_n(lcd_wr_n),.lcd_rd_n(lcd_rd_n));
tft_settings_renderer_reference renderer(.clk(clk),.x(x),.y(y),.packet(snapshot),.rgb565(pixel));
function[16:0]window_word;input[3:0]a;begin case(a)
0:window_word=17'h0002a;1,2,3:window_word=17'h10000;4:window_word=17'h100ef;
5:window_word=17'h0002b;6,7:window_word=17'h10000;8:window_word=17'h10001;
9:window_word=17'h1003f;10:window_word=17'h0002c;
default:window_word=0;endcase end endfunction
wire[16:0]window_entry=window_word(window_index);
always @(posedge clk or posedge rst)begin
 if(rst)begin
  state<=BOOT;next_state<=BOOT;wait_count<=0;request<=0;read_op<=0;rs<=1;write_data<=0;
  lcd_rst_n<=1;lcd_bl<=0;chip_id<=0;ready<=0;fault<=0;
  id_fallback<=0;st7789<=0;read_index<=0;init_index<=0;window_index<=0;pixel_wait<=0;
  x<=0;y<=0;snapshot<=0;
 end else begin
  request<=0;
  case(state)
   BOOT:if(wait_count==WAIT_20MS-1)begin wait_count<=0;lcd_rst_n<=0;state<=RESET_LOW;end else wait_count<=wait_count+1'b1;
   RESET_LOW:if(wait_count==WAIT_20MS-1)begin wait_count<=0;lcd_rst_n<=1;state<=RESET_HIGH;end else wait_count<=wait_count+1'b1;
   RESET_HIGH:if(wait_count==WAIT_120MS-1)begin wait_count<=0;state<=ID_CMD;end else wait_count<=wait_count+1'b1;
   ID_CMD:if(bus_idle)begin
    read_index<=0;chip_id<=0;read_op<=0;rs<=0;write_data<=id_fallback?16'h04:16'hd3;
    request<=1;next_state<=ID_READ;state<=WAIT_BUS;
   end
   ID_READ:if(bus_idle)begin read_op<=1;rs<=1;request<=1;next_state<=ID_READ;state<=WAIT_BUS;end
   ID_CHECK:begin
    if(chip_id==16'h9341||chip_id==16'h8552)begin st7789<=chip_id==16'h8552;init_index<=0;state<=INITIALIZE;end
    else if(!id_fallback)begin id_fallback<=1;state<=ID_CMD;end
    else begin fault<=1;wait_count<=0;state<=FAILED;end
   end
   INITIALIZE:begin
    if(init_entry[17:16]==3)begin snapshot<=packet;window_index<=0;x<=0;y<=0;state<=WINDOW;end
    else if(init_entry[17:16]==2)begin wait_count<=0;init_index<=init_index+1'b1;state<=INIT_DELAY;end
    else if(bus_idle)begin
     read_op<=0;rs<=init_entry[16];write_data<=init_entry[15:0];request<=1;
     init_index<=init_index+1'b1;next_state<=INITIALIZE;state<=WAIT_BUS;
    end
   end
   INIT_DELAY:if(wait_count==WAIT_120MS-1)begin wait_count<=0;state<=INITIALIZE;end else wait_count<=wait_count+1'b1;
   WINDOW:if(bus_idle)begin
    rs<=window_entry[16];write_data<=window_entry[15:0];read_op<=0;request<=1;
    window_index<=window_index+1'b1;
    next_state<=window_index==10?PIXEL_WAIT:WINDOW;pixel_wait<=0;state<=WAIT_BUS;
   end
   PIXEL_WAIT:if(pixel_wait==3)begin state<=PIXEL_SEND;end else pixel_wait<=pixel_wait+1'b1;
   PIXEL_SEND:if(bus_idle)begin
    write_data<=pixel;rs<=1;read_op<=0;request<=1;next_state<=PIXEL_SEND;state<=WAIT_BUS;
   end
   WAIT_BUS:if(bus_done)begin
    state<=next_state;
    if(next_state==ID_READ&&read_op)begin
     if(read_index==2)chip_id[15:8]<=read_data[7:0];
     if(read_index==3)begin chip_id[7:0]<=read_data[7:0];state<=ID_CHECK;end
     read_index<=read_index+1'b1;
    end
    if(next_state==PIXEL_SEND)begin
     pixel_wait<=0;state<=PIXEL_WAIT;
     if(x==239)begin x<=0;if(y==319)begin ready<=1;lcd_bl<=1;state<=WAIT_CHANGE;end else y<=y+1'b1;end
     else x<=x+1'b1;
    end
   end
   WAIT_CHANGE:if(packet!=snapshot)begin snapshot<=packet;window_index<=0;x<=0;y<=0;state<=WINDOW;end
   FAILED:begin
    lcd_bl<=0;
    if(wait_count==WAIT_120MS-1)begin
     wait_count<=0;id_fallback<=0;chip_id<=0;fault<=0;ready<=0;state<=BOOT;
    end else wait_count<=wait_count+1'b1;
   end
   default:state<=BOOT;
  endcase
 end
end
endmodule
