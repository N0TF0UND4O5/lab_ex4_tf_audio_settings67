
module sd_card_sec_read_write
#(
	parameter  SPI_LOW_SPEED_DIV = 248,         // spi clk speed = clk speed /((SPI_LOW_SPEED_DIV + 2) * 2 )
	parameter  SPI_HIGH_SPEED_DIV = 0           // spi clk speed = clk speed /((SPI_HIGH_SPEED_DIV + 2) * 2 )
)
(
	input            clk,
	input            rst,
	// 【第二轮板级修复新增】高有效：强制 SD 控制器重新走一遍初始化序列。
	// 用途：板级实测"第一张图正常、之后按 K2/K4 毫无反应"——
	//   典型原因是后续的 CMD17 取头失败后被卡在 S_CMD17 的无限重试里
	//   （cmd_req_ack & ~cmd_req_error 一直不成立），此后所有读请求都石沉大海。
	//   这里给一个"软复位"入口，把它拉回去重走 CMD0/CMD8/CMD55/CMD41/CMD16。
	//   **注意不清 sd_init_done**：这样 bmp_read / sd_card_bmp 不会被连带复位，
	//   已经扫到的图片表、已经显示的画面都不会丢。
	input            sd_reinit,
	// 【按键可靠性新增】单拍脉冲输出：通知 sd_card_cmd 补发 88 个唤醒时钟。
	//   在"上层软复位"和"本模块自愈"两种情况下都会发一次。
	output reg       cmd_wake,
	output reg       sd_init_done,
	input            sd_sec_read,
	input[31:0]      sd_sec_read_addr,
	output[7:0]      sd_sec_read_data,
	output           sd_sec_read_data_valid,
	output           sd_sec_read_end,
	input            sd_sec_write,
	input[31:0]      sd_sec_write_addr,
	input[7:0]       sd_sec_write_data,
	output           sd_sec_write_data_req,
	output           sd_sec_write_end,

	output reg[15:0] spi_clk_div,
	output reg       cmd_req,
	input            cmd_req_ack,
	input            cmd_req_error,
	output reg[47:0] cmd,
	output reg[7:0]  cmd_r1,
	output reg[15:0] cmd_data_len,
	output reg       block_read_req,
	input            block_read_valid,
	input[7:0]       block_read_data,
	input block_read_error,
	input            block_read_req_ack,
	output reg       block_write_req,
	output[7:0]      block_write_data,
	input            block_write_data_rd,
	input            block_write_req_ack
);
reg[7:0] read_data;
reg[31:0] timer;

localparam S_IDLE               = 0;
localparam S_CMD0               = 1;
localparam S_CMD8               = 2;
localparam S_CMD55              = 3;
localparam S_CMD41              = 4;
localparam S_CMD17              = 5;
localparam S_READ               = 6;
localparam S_CMD24              = 7;
localparam S_WRITE              = 8;
localparam S_ERR                = 14;
localparam S_WRITE_END          = 15;
localparam S_READ_END           = 16;
localparam S_WAIT_READ_WRITE    = 17;
localparam S_CMD16              = 18;

reg[4:0]                       state;
reg[31:0]                      sec_addr;
// 【按键可靠性】连续命令失败计数（卡不应答时命令会一直被重试，原来没有上限）
//   超过 CMD_ERR_MAX 就自己回到 S_CMD0 重走初始化 —— 保证"卡死后一定能爬出来"，
//   否则 S_CMD17 的无限重试会把按键彻底锁死。
reg[3:0]                       cmd_err_cnt;
localparam[3:0]                CMD_ERR_MAX = 4'd12;
// 【按键可靠性】读/写阶段的兜底超时（正常一次扇区读 ~170us @25MHz，
//   这里给 32ms，200 倍余量）。防止本模块永远停在 S_READ 等一个不会来的 ack。
reg[24:0]                      io_to_cnt;
localparam[24:0]               IO_TIMEOUT  = 25'd3_200_000;
reg                            sd_reinit_d;
assign sd_sec_read_data_valid = (state == S_READ) && block_read_valid;
assign sd_sec_read_data = block_read_data;
assign sd_sec_read_end = (state == S_READ_END);
assign sd_sec_write_data_req = (state == S_WRITE) && block_write_data_rd;
assign block_write_data = sd_sec_write_data;
assign sd_sec_write_end = (state == S_WRITE_END);

always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		cmd_req <= 1'b0;
		cmd_data_len <= 16'd0;
		cmd_r1 <= 8'd0;
		cmd <= 48'd0;
		spi_clk_div <= SPI_LOW_SPEED_DIV[15:0];
		block_write_req <= 1'b0;
		block_read_req <= 1'b0;
		sec_addr <= 32'd0;
		sd_init_done <= 1'b0;
		cmd_err_cnt <= 4'd0;
		io_to_cnt <= 25'd0;
		sd_reinit_d <= 1'b0;
		cmd_wake <= 1'b0;
	end
	else begin
		// ---- 【按键可靠性】命令错误计数 / 读写兜底超时 / 唤醒脉冲 ----
		sd_reinit_d <= sd_reinit;
		cmd_wake    <= sd_reinit & ~sd_reinit_d;      // 软复位起始一拍：补发唤醒时钟

		if (cmd_req_ack && ~cmd_req_error)
			cmd_err_cnt <= 4'd0;                      // 任一命令成功即清零
		else if (cmd_req_ack && cmd_req_error)
			cmd_err_cnt <= (cmd_err_cnt == 4'hF) ? 4'hF : (cmd_err_cnt + 4'd1);

		if ((state == S_READ) || (state == S_WRITE)) begin
			if (io_to_cnt != IO_TIMEOUT) io_to_cnt <= io_to_cnt + 25'd1;
		end else
			io_to_cnt <= 25'd0;

		if(sd_reinit == 1'b1)
		begin
		// 软复位：回到初始化序列（S_CMD0 -> S_CMD8 -> S_CMD55 -> S_CMD41 -> S_CMD16
		//            -> S_WAIT_READ_WRITE）；sd_init_done 保持为 1，不惊动上层。
		state           <= S_CMD0;
		cmd_req         <= 1'b0;
		block_read_req  <= 1'b0;
		block_write_req <= 1'b0;
		spi_clk_div     <= SPI_LOW_SPEED_DIV[15:0];
	end
	// ---- 【按键可靠性】自愈 1：连续命令失败到上限 -> 重走初始化 ----
	//   原来 S_CMD17 会无限重试，卡一不应答就永远出不来，按键彻底失效。
	else if(block_read_error || (cmd_req_ack && cmd_req_error && (cmd_err_cnt >= CMD_ERR_MAX)))
	begin
		state           <= S_CMD0;
		cmd_req         <= 1'b0;
		block_read_req  <= 1'b0;
		block_write_req <= 1'b0;
		cmd_err_cnt     <= 4'd0;
		cmd_wake        <= 1'b1;                      // 顺带补发唤醒时钟
	end
	// ---- 【按键可靠性】自愈 2：读/写阶段卡住超过 32ms -> 重走初始化 ----
	else if(((state == S_READ) || (state == S_WRITE)) && (io_to_cnt >= IO_TIMEOUT))
	begin
		state           <= S_CMD0;
		cmd_req         <= 1'b0;
		block_read_req  <= 1'b0;
		block_write_req <= 1'b0;
		io_to_cnt       <= 25'd0;
		cmd_wake        <= 1'b1;
	end
	else
		case(state)
			S_IDLE:
			begin
				state <= S_CMD0;
				sd_init_done <= 1'b0;
				spi_clk_div <= SPI_LOW_SPEED_DIV[15:0];
			end
			S_CMD0:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD8;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h01;
					cmd <= {8'd0,8'h00,8'h00,8'h00,8'h00,8'h95};
				end
			end
			S_CMD8:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD55;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd4;
					cmd_r1 <= 8'h01;
					cmd <= {8'd8,8'h00,8'h00,8'h01,8'haa,8'h87};
				end
			end
			S_CMD55:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD41;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h01;
					cmd <= {8'd55,8'h00,8'h00,8'h00,8'h00,8'hff};
				end
			end
			S_CMD41:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD16;
					cmd_req <= 1'b0;
					sd_init_done <= 1'b1;
					spi_clk_div <= SPI_HIGH_SPEED_DIV[15:0];
				end
				else if(cmd_req_ack)
				begin
					state <= S_CMD55;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd41,8'h40,8'h00,8'h00,8'h00,8'hff};
				end
			end
			S_CMD16:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_WAIT_READ_WRITE;
					cmd_req <= 1'b0;
					sd_init_done <= 1'b1;
					spi_clk_div <= SPI_HIGH_SPEED_DIV[15:0];
				end
				else if(cmd_req_ack)
				begin
					state <= S_CMD55;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd16,32'd512,8'hff};
				end
			end			
			S_WAIT_READ_WRITE:
			begin
				if(sd_sec_write ==  1'b1)
				begin
					state <= S_CMD24;
					sec_addr <= sd_sec_write_addr;
				end
				else if(sd_sec_read == 1'b1)
				begin
					state <= S_CMD17;
					sec_addr <= sd_sec_read_addr;
				end

				spi_clk_div <= 16'd0;
			end
			S_CMD24:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_WRITE;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd24,sec_addr,8'hff};

				end
			end
			S_WRITE:
			begin
				if(block_write_req_ack == 1'b1)
				begin
					block_write_req <= 1'b0;
					state <= S_WRITE_END;
				end
				else
					block_write_req <= 1'b1;
			end
			S_CMD17:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_READ;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd17,sec_addr,8'hff};
				end
			end
			S_READ:
			begin
				if(block_read_req_ack)
				begin
					state <= S_READ_END;
					block_read_req <= 1'b0;
				end
				else
				begin
					block_read_req <= 1'b1;
				end
			end
			S_WRITE_END:
			begin
				state <= S_WAIT_READ_WRITE;
			end
			S_READ_END:
			begin
				state <= S_WAIT_READ_WRITE;
			end
			default:
				state <= S_IDLE;
		endcase
	end
end
endmodule