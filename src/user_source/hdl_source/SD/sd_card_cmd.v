
module sd_card_cmd(
	input                       sys_clk,
	input                       rst,
	input[15:0]                 spi_clk_div,                  //SPI module clock division parameter
	input                       cmd_req,                      //SD card command request
	// 【按键可靠性新增】单拍脉冲：强制本模块重发 88 个唤醒时钟（CS 高）后再回到 S_WAIT。
	//   用途：卡在长时间空闲后可能不响应命令；上层软复位时顺带补足规范要求的
	//   "CS 高 + ≥74 个时钟"唤醒序列，让软复位真的能把卡拉回来。
	input                       cmd_reinit,
	output                      cmd_req_ack,                  //SD card command request response
	output reg                  cmd_req_error,                //SD card command request error
	input[47:0]                 cmd,                          //SD card command
	input[7:0]                  cmd_r1,                       //SD card expect response
	input[15:0]                 cmd_data_len,                 //SD card command read data length
	input                       block_read_req,               //SD card sector data read request
	output reg                  block_read_valid,             //SD card sector data read data valid
	output reg[7:0]             block_read_data,              //SD card sector data read data
	output                      block_read_error,
	output                      block_read_req_ack,           //SD card sector data read response
	input                       block_write_req,              //SD card sector data write request
	input[7:0]                  block_write_data,             //SD card sector data write data next clock is valid
	output                      block_write_data_rd,          //SD card sector data write data
	output                      block_write_req_ack,          //SD card sector data write response
	output                      nCS_ctrl,                     //SPI module chip select control
	output reg[15:0]            clk_div,
	output reg                  spi_wr_req,                   //SPI module data sending request
	input                       spi_wr_ack,                   //SPI module data request response
	output[7:0]                 spi_data_in,                  //SPI module send data
	input[7:0]                  spi_data_out                  //SPI module data returned
);
parameter S_IDLE         = 0;
parameter S_WAIT         = 1;
parameter S_INIT         = 2;
parameter S_CMD_PRE      = 3;
parameter S_CMD          = 4;
parameter S_CMD_DATA     = 5;
parameter S_READ_WAIT    = 6;
parameter S_READ         = 7;
parameter S_READ_ACK     = 8;
parameter S_WRITE_TOKEN  = 9;
parameter S_WRITE_DATA_0 = 10;
parameter S_WRITE_DATA_1 = 11;
parameter S_WRITE_CRC    = 12;
parameter S_WRITE_SUC    = 13;
parameter S_WRITE_BUSY   = 14;
parameter S_WRITE_ACK    = 15;
parameter S_ERR          = 16;
parameter S_END          = 17;

reg[4:0]                      state;
reg                           CS_reg;
reg[15:0]                     byte_cnt;
reg[7:0]                      send_data;
wire[7:0]                     data_recv;
reg[9:0]                      wr_data_cnt;

reg [15:0] read_crc;
reg [7:0] read_crc_hi;
reg read_crc_bad;
function [15:0] crc16_byte;
    input [15:0] previous;
    input [7:0] value;
    reg [15:0] c;
    integer i;
    begin
        c = previous ^ {value, 8'h00};
        for (i=0; i<8; i=i+1)
            c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
        crc16_byte = c;
    end
endfunction
assign block_read_error = ((state == S_END) && read_crc_bad);
always @(posedge sys_clk or posedge rst) begin
    if (rst) begin read_crc <= 0; read_crc_hi <= 0; read_crc_bad <= 0; end
    else if (cmd_reinit || state == S_WAIT) begin
        read_crc <= 0; read_crc_hi <= 0; read_crc_bad <= 0;
    end else if (state == S_READ_WAIT && spi_wr_ack && data_recv == 8'hfe)
        read_crc <= 0;
    else if (state == S_READ && spi_wr_ack) begin
        if (byte_cnt < 512) read_crc <= crc16_byte(read_crc, data_recv);
        else if (byte_cnt == 512) read_crc_hi <= data_recv;
        else if (byte_cnt == 513) read_crc_bad <= ({read_crc_hi, data_recv} != read_crc);
    end else if (state == S_READ_WAIT && spi_wr_ack && byte_cnt == 65535)
        read_crc_bad <= 1; // token timeout must restart CMD17, never hunt in payload.
end
assign cmd_req_ack = (state == S_END);
assign block_read_req_ack = (state == S_READ_ACK);
assign block_write_req_ack= (state == S_WRITE_ACK);
assign block_write_data_rd = (state == S_WRITE_DATA_0);
assign spi_data_in = send_data;
assign data_recv = spi_data_out;
assign nCS_ctrl = CS_reg;
always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		CS_reg <= 1'b1;
		spi_wr_req <= 1'b0;
		byte_cnt <= 16'd0;
		clk_div <= 16'd0;
		send_data <= 8'hff;
		state <= S_IDLE;
		cmd_req_error <= 1'b0;
		wr_data_cnt <= 10'd0;
	end
	// 【按键可靠性】软复位唤醒：补发 S_INIT 的 11 个 0xff（88 个时钟、CS 高），
	//   然后回 S_WAIT 继续接收命令。这一条同时是"卡不应答"的唯一逃生口 ——
	//   原来任何一处死等都没有出口，下层一卡死，上层所有重试/软复位全部失效。
	else if(cmd_reinit == 1'b1)
	begin
		state      <= S_INIT;
		byte_cnt   <= 16'd0;
		spi_wr_req <= 1'b0;
		CS_reg     <= 1'b1;
		send_data  <= 8'hff;
	end
	else
		case(state)
			S_IDLE:
			begin
				state <= S_INIT;
				clk_div <= spi_clk_div;
				CS_reg <= 1'b1;
			end
			S_INIT:
			begin
				//send 11 bytes on power(at least 74 SPI clocks)
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt >= 16'd10)
					begin
						byte_cnt <= 16'd0;
						spi_wr_req <= 1'b0;
						state <= S_WAIT;
					end
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WAIT:
			begin
				cmd_req_error <= 1'b0;
				wr_data_cnt <= 10'd0;
				//wait for  instruction
				if(cmd_req == 1'b1)
					state <= S_CMD_PRE;
				else if(block_read_req == 1'b1)
				begin
					state    <= S_READ_WAIT;
					byte_cnt <= 16'd0;          // 上面的 0xFE 超时计数从这里开始
				end
				else if(block_write_req == 1'b1)
					state <= S_WRITE_TOKEN;
				clk_div <= spi_clk_div;
			end
			S_CMD_PRE:
			begin
				//before sending a command, send an byte 'ff',provide some clocks
				if(spi_wr_ack == 1'b1)
				begin
					state <= S_CMD;
					spi_wr_req <= 1'b0;
					byte_cnt <= 16'd0;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					CS_reg <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_CMD:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if((byte_cnt == 16'hffff) || (data_recv != cmd_r1 && data_recv[7] == 1'b0))
					begin
						state <= S_ERR;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else if(data_recv == cmd_r1)
					begin
						spi_wr_req <= 1'b0;
						if(cmd_data_len != 16'd0)
						begin
							state <= S_CMD_DATA;
							byte_cnt <= 16'd0;
						end
						else
						begin
							state <= S_END;
							byte_cnt <= 16'd0;
						end
					end
					else
						byte_cnt <=  byte_cnt + 16'd1;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					CS_reg <= 1'b0;
					if(byte_cnt == 16'd0)
						send_data <= (cmd[47:40] | 8'h40);
					else if(byte_cnt == 16'd1)
						send_data <= cmd[39:32];
					else if(byte_cnt == 16'd2)
						send_data <= cmd[31:24];
					else if(byte_cnt == 16'd3)
						send_data <= cmd[23:16];
					else if(byte_cnt == 16'd4)
						send_data <= cmd[15:8];
					else if(byte_cnt == 16'd5)
						send_data <= cmd[7:0];
					else
						send_data <= 8'hff;
				end
			end
			S_CMD_DATA:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt == cmd_data_len - 16'd1)
					begin
						state <= S_END;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_READ_WAIT:
			begin
				if(spi_wr_ack == 1'b1 && data_recv == 8'hfe)
				begin
					spi_wr_req <= 1'b0;
					state <= S_READ;
					byte_cnt <= 16'd0;
				end
				// 【按键可靠性 —— 关键修复】等数据起始令牌 0xFE 的超时。
				//   原来这里没有任何超时：卡一旦不给 0xFE（不应答/被复位/上一次读没读完），
				//   本模块就永远卡在 S_READ_WAIT 里，cmd_req_ack 再也不出现，于是
				//   sd_card_sec_read_write 永远等 block_read_req_ack、bmp_read 永远等
				//   sd_sec_read_end —— 上层的"1 秒超时 + 软复位 + 重试"整条恢复链
				//   全部形同虚设（软复位只能复位 SD 控制器上层 FSM，碰不到这里）。
				//   ⚠⚠ 【2026-10-06 晚·重要修正】原来设成 4096 字节（1.3ms）**太小**：
				//   我们每次"发起加载"前都会给卡一个 CMD0 软复位，而卡被 CMD0 复位后
				//   要忙**几毫秒到几十毫秒**才肯给数据令牌 —— 1.3ms 的超时会在这段时间里
				//   先超时，然后（因为 block_read_req 还高着）控制器又回到 S_READ_WAIT
				//   重新轮询，此时卡**正在发数据**了 ⇒ 控制器会把数据中间某个 0xFE
				//   当成令牌 ⇒ **整扇区内容前移、字节数仍是 512**
				//   —— 这正是板上"图像横移/上移、缺字量每次不同"的根源
				//   （也解释了为什么**扫描阶段**（不重置卡）读得对、**加载**读得错）。
				//   现在改成 65535 字节 ≈ 21ms：足够覆盖卡复位后的忙期，
				//   仍保留"永远不出逃"的兜底（上层还有 4 秒加载超时）。
				else if(spi_wr_ack == 1'b1 && byte_cnt >= 16'd65535)
				begin
					spi_wr_req <= 1'b0;
					byte_cnt   <= 16'd0;
					state      <= S_ERR;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
					if(spi_wr_ack == 1'b1)
						byte_cnt <= byte_cnt + 16'd1;
				end
			end
			S_READ:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt == 16'd513)
					begin
						state <= ({read_crc_hi, data_recv} == read_crc) ? S_READ_ACK : S_ERR;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WRITE_TOKEN:
				if(spi_wr_ack == 1'b1)
				begin
					state <= S_WRITE_DATA_0;
					spi_wr_req <= 1'b0;
					byte_cnt <= 16'd0;  
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hfe;
				end
			S_WRITE_DATA_0:
			begin
				state <= S_WRITE_DATA_1;
				wr_data_cnt <= wr_data_cnt + 10'd1;
			end
			S_WRITE_DATA_1:
			begin
				if(spi_wr_ack == 1'b1 && wr_data_cnt == 10'd512)
				begin
					state <= S_WRITE_CRC;
					spi_wr_req <= 1'b0;
				end
				else if(spi_wr_ack == 1'b1)
				begin
					state <= S_WRITE_DATA_0;
					spi_wr_req <= 1'b0;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= block_write_data;
				end
			end
			S_WRITE_CRC:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt == 16'd1)
					begin
						state <= S_WRITE_SUC;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WRITE_SUC :
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(data_recv[4:0] == 5'b00101)
					begin
						state <= S_WRITE_BUSY;
						spi_wr_req <= 1'b0;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WRITE_BUSY :
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(data_recv == 8'hff)
					begin
						state <= S_WRITE_ACK;
						spi_wr_req <= 1'b0;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_ERR:
			begin
				state <= S_END;
				cmd_req_error <= 1'b1;
			end
			S_READ_ACK,S_WRITE_ACK,S_END:
			begin
				state <= S_WAIT;
			end
			default:
				state <= S_IDLE;
		endcase
end
always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
		block_read_valid <= 1'b0;
	else if(state == S_READ && byte_cnt < 16'd512)
		block_read_valid <= spi_wr_ack;
	else
		block_read_valid <= 1'b0;
end

always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
		block_read_data <= 8'd0;
	else if(state == S_READ && spi_wr_ack == 1'b1)
		block_read_data <= data_recv;
end

endmodule