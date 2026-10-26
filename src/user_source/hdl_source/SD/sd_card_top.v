
module sd_card_top
#(
	parameter  SPI_LOW_SPEED_DIV = 248,         // SD card low speed mode frequency division parameter,spi clk speed = clk speed /((SPI_LOW_SPEED_DIV + 2) * 2 )
	parameter  SPI_HIGH_SPEED_DIV = 0           // SD card high speed mode frequency division parameter,spi clk speed = clk speed /((SPI_HIGH_SPEED_DIV + 2) * 2 )
)
(
	input            clk,
	input            rst,
	input            stream_ready,
	input            sd_reinit,                 //SD card controller soft re-init (recovery)
	output           SD_nCS,                    //SD card chip select (SPI mode)
	output           SD_DCLK,                   //SD card clock
	output           SD_MOSI,                   //SD card controller data output
	input            SD_MISO,                   //SD card controller data input
	output           sd_init_done,              //SD card initialization is complete
	input            sd_sec_read,               //SD card sector read
	input[31:0]      sd_sec_read_addr,          //SD card sector read address
	output[7:0]      sd_sec_read_data,          //SD card sector read data
	output           sd_sec_read_data_valid,    //SD card sector read data valid
	output           sd_sec_read_end,           //SD card sector read end
	input            sd_sec_write,              //SD card sector write
	input[31:0]      sd_sec_write_addr,         //SD card sector write address
	input[7:0]       sd_sec_write_data,         //SD card sector write data
	output           sd_sec_write_data_req,     //SD card sector write data next clock is valid
	output           sd_sec_write_end           //SD card sector write end
);
wire [7:0] raw_read_data;
wire raw_read_valid, raw_read_end, block_read_error;
wire [7:0] checked_read_data;
wire checked_read_valid, checked_read_end, sector_draining;
sd_sector_buffer u_sector_buffer (
    .clk(clk), .rst(rst), .abort_read(sd_reinit || cmd_wake),
    .emit_ready(stream_ready),
    .raw_data(raw_read_data), .raw_valid(raw_read_valid), .raw_end(raw_read_end),
    .data(checked_read_data), .valid(checked_read_valid), .read_end(checked_read_end),
    .draining(sector_draining)
);
assign sd_sec_read_data = checked_read_data;
assign sd_sec_read_data_valid = checked_read_valid;
assign sd_sec_read_end = checked_read_end;
wire[15:0]           spi_clk_div;               //SPI module clock division parameter
wire                 cmd_req;                   //SD card command request
wire                 cmd_req_ack;               //SD card command request response
wire                 cmd_req_error;             //SD card command request error
wire[47:0]           cmd;                       //SD card command
wire[7:0]            cmd_r1;                    //SD card expect response
wire[15:0]           cmd_data_len;              //SD card command read data length
wire                 block_read_req;            //SD card sector data read request
wire                 block_read_valid;          //SD card sector data read data valid
wire[7:0]            block_read_data;           //SD card sector data read data
wire                 block_read_req_ack;        //SD card sector data read response
wire                 block_write_req;           //SD card sector data write request
wire[7:0]            block_write_data;          //SD card sector data write data next clock is valid
wire                 block_write_data_rd;       //SD card sector data write data
wire                 block_write_req_ack;       //SD card sector data write response
wire                 cmd_wake;                  //唤醒脉冲：通知 cmd 层补发 88 个时钟

wire                 nCS_ctrl;                  //SPI module chip select control
wire                 spi_wr_req;                //SPI module data sending request
wire                 spi_wr_ack;                //SPI module data request response
wire[7:0]            spi_data_in;               //SPI module send data
wire[7:0]            spi_data_out;              //SPI module data returned
wire[15:0]           clk_div;
sd_card_sec_read_write
#(
	.SPI_LOW_SPEED_DIV(SPI_LOW_SPEED_DIV),
	.SPI_HIGH_SPEED_DIV(SPI_HIGH_SPEED_DIV)
)
sd_card_sec_read_write_m0(
	.clk                            (clk                    ),
	.rst                            (rst                    ),
	.sd_reinit                      (sd_reinit              ),
	.cmd_wake                       (cmd_wake               ),
	.sd_init_done                   (sd_init_done           ),
	.sd_sec_read                    (sd_sec_read && !sector_draining && !raw_read_end && !checked_read_end),
	.sd_sec_read_addr               (sd_sec_read_addr       ),
	.sd_sec_read_data               (raw_read_data          ),
	.sd_sec_read_data_valid         (raw_read_valid         ),
	.sd_sec_read_end                (raw_read_end           ),
	.sd_sec_write                   (sd_sec_write           ),
	.sd_sec_write_addr              (sd_sec_write_addr      ),
	.sd_sec_write_data              (sd_sec_write_data      ),
	.sd_sec_write_data_req          (sd_sec_write_data_req  ),
	.sd_sec_write_end               (sd_sec_write_end       ),
	.spi_clk_div                    (spi_clk_div            ),
	.cmd_req                        (cmd_req                ),
	.cmd_req_ack                    (cmd_req_ack            ),
	.cmd_req_error                  (cmd_req_error          ),
	.cmd                            (cmd                    ),
	.cmd_r1                         (cmd_r1                 ),
	.cmd_data_len                   (cmd_data_len           ),
	.block_read_req                 (block_read_req         ),
	.block_read_valid               (block_read_valid       ),
	.block_read_data                (block_read_data        ),
	.block_read_req_ack             (block_read_req_ack     ),
    .block_read_error               (block_read_error       ),
	.block_write_req                (block_write_req        ),
	.block_write_data               (block_write_data       ),
	.block_write_data_rd            (block_write_data_rd    ),
	.block_write_req_ack            (block_write_req_ack    )
);

sd_card_cmd sd_card_cmd_m0(
	.sys_clk                        (clk                    ),
	.rst                            (rst                    ),
	.spi_clk_div                    (spi_clk_div            ),
	.cmd_req                        (cmd_req                ),
	.cmd_reinit                     (cmd_wake               ),
	.cmd_req_ack                    (cmd_req_ack            ),
	.cmd_req_error                  (cmd_req_error          ),
	.cmd                            (cmd                    ),
	.cmd_r1                         (cmd_r1                 ),
	.cmd_data_len                   (cmd_data_len           ),
	.block_read_req                 (block_read_req         ),
	.block_read_req_ack             (block_read_req_ack     ),
    .block_read_error               (block_read_error       ),
	.block_read_data                (block_read_data        ),
	.block_read_valid               (block_read_valid       ),
	.block_write_req                (block_write_req        ),
	.block_write_data               (block_write_data       ),
	.block_write_data_rd            (block_write_data_rd    ),
	.block_write_req_ack            (block_write_req_ack    ),
	.nCS_ctrl                       (nCS_ctrl               ),
	.clk_div                        (clk_div                ),
	.spi_wr_req                     (spi_wr_req             ),
	.spi_wr_ack                     (spi_wr_ack             ),
	.spi_data_in                    (spi_data_in            ),
	.spi_data_out                   (spi_data_out           )

);

spi_master spi_master_m0(
	.sys_clk                        (clk                    ),
	.rst                            (rst || sd_reinit || cmd_wake),
	.nCS                            (SD_nCS                 ),
	.DCLK                           (SD_DCLK                ),
	.MOSI                           (SD_MOSI                ),
	.MISO                           (SD_MISO                ),
	.clk_div                        (clk_div                ),
	.CPOL                           (1'b1                   ),
	.CPHA                           (1'b1                   ),
	.nCS_ctrl                       (nCS_ctrl               ),
	.wr_req                         (spi_wr_req             ),
	.wr_ack                         (spi_wr_ack             ),
	.data_in                        (spi_data_in            ),
	.data_out                       (spi_data_out           )
);
endmodule

// One sector is transactional: aborted/retried bytes never reach the BMP parser.
module sd_sector_buffer(
    input clk, rst, abort_read,
    input emit_ready,
    input [7:0] raw_data,
    input raw_valid, raw_end,
    output reg [7:0] data,
    output reg valid, read_end,
    output wire draining
);
reg [7:0] sector_mem [0:511];
reg [9:0] receive_count;
reg [8:0] emit_index;
reg finish_pending;
reg emitting;
assign draining = emitting || finish_pending || valid || read_end;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        receive_count <= 0; emit_index <= 0; emitting <=  0;
        valid <= 0; read_end <= 0; data <= 0; finish_pending <= 0;
    end else begin
        valid <= 0; read_end <= 0;
        if (abort_read) begin
            receive_count <= 0; emit_index <= 0; emitting <=  0;
            finish_pending <= 0;
        end else if (emitting && (emit_ready !== 1'b0)) begin
            data <= sector_mem[emit_index]; valid <= 1;
            if (emit_index == 511) begin
                emitting <=  0; finish_pending <= 1;
            end else emit_index <= emit_index + 1'b1;
        end else if (emitting) begin
            // Hold index and contents until downstream FIFO has room.
        end else if (finish_pending) begin
            read_end <= 1; finish_pending <= 0;
        end else begin
            if (raw_valid) begin
                if (receive_count < 512) sector_mem[receive_count[8:0]] <= raw_data;
                if (receive_count < 513) receive_count <= receive_count + 1'b1;
            end
            if (raw_end) begin
                if (receive_count == 512) begin
                    emitting <=  1; emit_index <= 0;
                end
                receive_count <= 0;
            end
        end
    end
end
endmodule
