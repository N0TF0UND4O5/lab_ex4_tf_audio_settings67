// ============================================================================
//  top_img_display.v  ——  TF 卡 BMP → HDMI 640x480 显示（自建工程）
//
//  为什么自建：原例程（APUG092 HDMI1.4b + frame_read_write）的帧缓存读写通路
//  存在稳定撕裂（画面有一块错位到屏幕另一侧），且首图之外的加载无法完成
//  （9 次加载只写完 1 帧）。该通路涉及 SDRAM 读写互斥仲裁 + 固定 21 拍读延迟
//  补偿 + "新请求会终止上一次事务并清空 FIFO"，难以在不读透 IP 的情况下修好。
//
//  本工程的做法：把这条通路整体换掉，让撕裂在结构上不可能发生。
//
//  ── 复用（官方已验证模块，一行未改）─────────────────────────────────────
//     sd_card_bmp / bmp_read / sd_card_top / sd_card_sec_read_write /
//     sd_card_cmd / spi_master        —— SD/SPI 读卡链路
//     sys_pll / video_pll             —— 时钟
//     video_rgb_to_axis_640x480       —— RGB+DE/VS → AXI-Stream
//     hdmi_1_4b_transmitter_core_wrapper / hdmi_phy_wrapper  —— HDMI 输出
//     startup_pulse / seg_decoder / seg_scan
//
//  ── 废弃（撕裂来源，本工程不再例化）─────────────────────────────────────
//     frame_read_write, frame_fifo_write, frame_fifo_read,
//     video_timing_data, video_delay, color_bar, sdram(整颗 SDRAM)
//
//  ── 自写（本文件）───────────────────────────────────────────────────────
//     my_video_timing  640x480@60 时序（800x525），与 HDMI 核参数逐项对齐
//     frame_store      帧缓存：320x240 RGB332 单缓冲 BRAM，双时钟双端口
//     top_img_display  顶层
//
//  ── 关键设计 ────────────────────────────────────────────────────────────
//   1) 没有 SDRAM、没有读写仲裁、没有 FIFO 清空语义 → 结构上不可能撕裂
//   2) BRAM 写口用 sd_card_clk(100MHz)、读口用 video_clk(25MHz)，
//      两端天然独立，不需要任何跨域握手
//   3) 读出时整数 2 倍放大：rd_addr = (y/2)*320 + (x/2)，零额外资源
//   4) 管线对齐只有 2 拍（BRAM 读 1 拍 + 打 1 拍），替代原来脆弱的固定 21 拍
//
//  ── 资源与分辨率权衡 ────────────────────────────────────────────────────
//    EG4S20 的 BRAM 共 1008 Kbit = 126 KB。
//    640x480 24bit = 921600 字节，远远放不下；即使 8bit 也要 307200 字节。
//    320x240 8bit(RGB332) = 76800 字节 ✓ 放得下。
//    320x240 的 2 倍正好是 640x480，所以放大是整数倍的、极简单。
//    显示分辨率仍是 **640x480@60**，HDMI 时序与核参数完全不变。
//    （若将来要 640x480 原生画质，必须回到 SDRAM 通路，但要用"写完整帧再切显示"
//      的简单单缓冲 + 行缓存读法，而不是那套仲裁+FIFO。）
//
//  ── 集成步骤 ────────────────────────────────────────────────────────────
//   A. 源码：把本文件放进 src/user_source/hdl_source/ 并加入 TD 工程。
//      其余源文件保持与 project2 一致（含那份 TD 语法版 timing.sdc）。
//      **不要把 sdram.v / frame_read_write.v / frame_fifo_*.v /
//        video_timing_data.v / video_delay.v / color_bar.v 加入编译**
//      （留着无妨，但别例化；不例化时加入编译也只是占综合时间）。
//   B. 顶层文件名/模块名：把工程顶层设为 top_img_display（模块名与文件名一致）。
//      **端口名与原 top 完全一致** → pin.adc（引脚约束）**一行都不用改**。
//   C. 时钟约束：timing.sdc 里原有的 create_clock 仍适用于 clk /
//      sd_card_clk / ext_mem_clk / video_clk / hdmi_5x_clk。
//      ext_mem_clk 现在没有负载（SDRAM 已移除），可保留无害。
//   D. 图片：TF 卡里必须放 **320x240 24bit 非压缩 BMP**。
//      用 doc/convert/convert_images_to_bmp.py 转换前，把脚本里的目标尺寸
//      改成 (320, 240)（或直接用 Pillow：Image.open(f).resize((320,240)).save(...)）。
//      转换后用 doc/convert/sync_to_sd.py 同步到卡（它会破坏旧图残留的 BM 头）。
//   E. 数码管：最右一位显示 state_code（1 空闲 / 2 扫描或取头 / 3 等握手 / 4 读像素），
//      其余位不亮，与原例程一致。
//
//  ── 已知取舍 ────────────────────────────────────────────────────────────
//   * 单缓冲：切换图片时新图是"自上而下写入"的（约 0.4 秒铺满），没有撕裂，
//     但会有可见的写入过程。若接受不了，可加第二块缓冲（76800*2=153600 字节
//     > 126KB，放不下），或改用 16 色 4bit（640x480x4bit 也放不下）——
//     双缓冲在 BRAM 容量下做不到，需要走 SDRAM。
//   * 256 色 + 2 倍放大，画质不如原生 24bit。
// ============================================================================
`timescale 1ns/1ps


// ---------------------------------------------------------------------------
// 1) 视频时序发生器：640x480@60（800x525），与 HDMI 核的
//    HTOTAL/HSA/HFP/HBP/VTOTAL/VSA/VFP/VBP 逐项对齐
//    负极性同步（与原 color_bar 的 VIDEO_640_480 配置一致）
// ---------------------------------------------------------------------------
module my_video_timing #(
    parameter H_ACTIVE = 640,
    parameter H_FP     = 16,
    parameter H_SYNC   = 96,
    parameter H_BP     = 48,
    parameter V_ACTIVE = 480,
    parameter V_FP     = 10,
    parameter V_SYNC   = 2,
    parameter V_BP     = 33
)(
    input             clk,
    input             rst,
    output            hs,
    output            vs,
    output            de,
    output [9:0]      x,
    output [9:0]      y
);
    localparam H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 800
    localparam V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 525

    reg [9:0] hcnt;
    reg [9:0] vcnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hcnt <= 10'd0;
            vcnt <= 10'd0;
        end else if (hcnt == H_TOTAL - 1) begin
            hcnt <= 10'd0;
            vcnt <= (vcnt == V_TOTAL - 1) ? 10'd0 : (vcnt + 10'd1);
        end else begin
            hcnt <= hcnt + 10'd1;
        end
    end

    wire h_sync_on = (hcnt >= H_ACTIVE + H_FP) && (hcnt < H_ACTIVE + H_FP + H_SYNC);
    wire v_sync_on = (vcnt >= V_ACTIVE + V_FP) && (vcnt < V_ACTIVE + V_FP + V_SYNC);

    assign hs = ~h_sync_on;
    assign vs = ~v_sync_on;
    assign de = (hcnt < H_ACTIVE) && (vcnt < V_ACTIVE);
    assign x  = hcnt;
    assign y  = vcnt;

endmodule


// ---------------------------------------------------------------------------
// 2) 帧缓存：320x240 RGB332 单缓冲 BRAM，写入端与读出端时钟独立
//    写侧：sd_card_clk 域，来自 sd_card_bmp 的 write_req/ack + write_en/write_data
//          write_data[31:8] = {R,G,B} 各 8bit（与 bmp_read 的输出格式一致）
//          每收满 SRC_W*SRC_H 个像素翻转一次 write_finish_toggle
//    读侧：video_clk 域，组合地址进、1 拍出数据
// ---------------------------------------------------------------------------
module frame_store #(
    parameter SRC_W = 320,
    parameter SRC_H = 240
)(
    // 写侧（sd_card_clk）
    input               wr_clk,
    input               wr_rst,
    input               write_req,
    output reg          write_req_ack,
    input               write_en,
    input  [31:0]       write_data,
    output reg          write_finish_toggle,
    output [16:0]       wr_pix_cnt,

    // 读侧（video_clk）
    input               rd_clk,
    input  [16:0]       rd_addr,
    output [7:0]        rd_data
);
    localparam DEPTH = SRC_W * SRC_H;          // 76800

    reg [7:0] mem [0:DEPTH-1];

    reg        wr_busy;
    reg [16:0] wr_addr;
    reg [16:0] wr_cnt;
    reg [7:0]  rd_q;

    assign wr_pix_cnt = wr_cnt;
    assign rd_data    = rd_q;

    always @(posedge wr_clk or posedge wr_rst) begin
        if (wr_rst) begin
            wr_busy             <= 1'b0;
            wr_addr             <= 17'd0;
            wr_cnt              <= 17'd0;
            write_req_ack       <= 1'b0;
            write_finish_toggle <= 1'b0;
        end else begin
            // ---- 四相握手：req 抬起给 ack，req 撤销后 ack 落下并开始写新一帧 ----
            if (write_req) begin
                write_req_ack <= 1'b1;
            end else begin
                if (write_req_ack) begin
                    wr_busy <= 1'b1;
                    wr_addr <= 17'd0;
                    wr_cnt  <= 17'd0;
                end
                write_req_ack <= 1'b0;
            end

            // ---- 收像素，取高 3/3/2 位存成 RGB332 ----
            if (wr_busy && write_en) begin
                mem[wr_addr] <= {write_data[31:29],    // R[7:5]
                                 write_data[23:21],    // G[7:5]
                                 write_data[15:14]};   // B[7:6]
                wr_addr <= wr_addr + 17'd1;
                wr_cnt  <= wr_cnt  + 17'd1;
                if (wr_cnt == DEPTH - 1) begin
                    wr_busy             <= 1'b0;
                    write_finish_toggle <= ~write_finish_toggle;
                end
            end
        end
    end

    // ---- 读口（独立时钟，无仲裁）----
    always @(posedge rd_clk) begin
        rd_q <= mem[rd_addr];
    end

endmodule


// ---------------------------------------------------------------------------
// 3) 顶层（端口名与原 top 完全一致，pin.adc 不用改）
// ---------------------------------------------------------------------------
module top_img_display (
    input                       clk,            // 50 MHz
    input                       rst_n,          // 低有效
    input                       key1,           // 手动下一张（板上 KEY2 / B2）
    input                       key2,           // 自动轮播开关（板上 KEY4 / C1）

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

    localparam SRC_W = 320;
    localparam SRC_H = 240;

    // ================= 复位：POR，等两路 PLL 锁定并稳定 20ms =================
    wire sys_pll_lock;
    wire video_pll_lock;
    wire rst_all;

    reg [19:0] rst_cnt;
    reg        rst_all_reg;

    always @(posedge clk) begin
        if (!rst_n) begin
            rst_cnt     <= 20'd0;
            rst_all_reg <= 1'b1;
        end else if (!rst_all_reg) begin
            rst_all_reg <= 1'b0;              // 释放后不再回头，防 PLL 抖动误复位
        end else if (sys_pll_lock && video_pll_lock) begin
            if (rst_cnt < 20'd1_000_000) begin
                rst_cnt     <= rst_cnt + 1'b1;
                rst_all_reg <= 1'b1;
            end else begin
                rst_all_reg <= 1'b0;
            end
        end else begin
            rst_cnt     <= 20'd0;
            rst_all_reg <= 1'b1;
        end
    end

    assign rst_all = rst_all_reg;

    // ================= 时钟 =================
    wire sd_card_clk;
    wire ext_mem_clk;
    wire ext_mem_clk_sft;
    wire video_clk;
    wire hdmi_5x_clk;

    sys_pll sys_pll_m0 (
        .refclk     (clk),
        .reset      (1'b0),
        .extlock    (sys_pll_lock),
        .clk0_out   (sd_card_clk),
        .clk1_out   (ext_mem_clk),
        .clk2_out   (ext_mem_clk_sft)
    );

    video_pll video_pll_m0 (
        .refclk     (clk),
        .reset      (1'b0),
        .extlock    (video_pll_lock),
        .clk0_out   (video_clk),
        .clk1_out   (hdmi_5x_clk)
    );

    // ================= SD 读图链路（复用官方模块） =================
    wire [3:0]  state_code;
    wire        display_valid;
    wire [1:0]  write_buf_idx;
    wire [1:0]  disp_buf_idx;
    wire        sd_wr_req;
    wire        sd_wr_ack;
    wire        sd_wr_en;
    wire [31:0] sd_wr_data;
    wire        frame_wr_fin_tgl;

    sd_card_bmp #(
        .CLK_FREQ_HZ         (100_000_000),
        .SCAN_START_SECTOR   (32'd0),
        .SCAN_MAX_SECTOR     (32'd131071),
        .SCAN_TARGET_COUNT   (3'd4),
        .LOAD_TIMEOUT_CYCLES (32'd100_000_000)   // 1s 兜底
    ) sd_card_bmp_m0 (
        .clk                 (sd_card_clk),
        .rst                 (rst_all),
        .key_next            (key1),
        .key_auto            (key2),
        .bmp_width           (SRC_W),
        .bmp_height          (SRC_H),
        .display_valid       (display_valid),
        .state_code          (state_code),

        .write_finish_toggle (frame_wr_fin_tgl),
        .write_buf_idx       (write_buf_idx),
        .disp_buf_idx        (disp_buf_idx),

        .write_req           (sd_wr_req),
        .write_req_ack       (sd_wr_ack),
        .write_en            (sd_wr_en),
        .write_data          (sd_wr_data),

        .SD_nCS              (sd_ncs),
        .SD_DCLK             (sd_dclk),
        .SD_MOSI             (sd_mosi),
        .SD_MISO             (sd_miso)
    );

    // ================= 视频时序 =================
    wire       hs, vs, de;
    wire [9:0] px, py;

    my_video_timing my_video_timing_m0 (
        .clk   (video_clk),
        .rst   (rst_all),
        .hs    (hs),
        .vs    (vs),
        .de    (de),
        .x     (px),
        .y     (py)
    );

    // ================= 帧缓存 =================
    // 放大 2 倍：rd_addr = (y/2)*320 + (x/2)，只在有效区内取地址，保证不越界
    wire [8:0]  ax;
    wire [8:0]  ay;
    wire [16:0] rd_addr;
    wire [7:0]  rd_byte;

    assign ax      = de ? px[9:1] : 9'd0;
    assign ay      = de ? py[9:1] : 9'd0;
    assign rd_addr = ay * 9'd320 + ax;         // 最大 239*320+319 = 76799 = DEPTH-1 ✓

    frame_store #(
        .SRC_W (SRC_W),
        .SRC_H (SRC_H)
    ) frame_store_m0 (
        .wr_clk              (sd_card_clk),
        .wr_rst              (rst_all),
        .write_req           (sd_wr_req),
        .write_req_ack       (sd_wr_ack),
        .write_en            (sd_wr_en),
        .write_data          (sd_wr_data),
        .write_finish_toggle (frame_wr_fin_tgl),
        .wr_pix_cnt          (),
        .rd_clk              (video_clk),
        .rd_addr             (rd_addr),
        .rd_data             (rd_byte)
    );

    // ============ RGB332 → RGB888，并把 de/hs/vs 对齐到 2 拍 ============
    // 时序：计数器出 (x,y,de)  → 第 1 拍 BRAM 出 rgb332  → 第 2 拍 rgb 就绪
    wire [23:0] rgb_now = {rd_byte[7:5], rd_byte[7:5], rd_byte[7],     // R8
                           rd_byte[4:2], rd_byte[4:2], rd_byte[4],     // G8
                           rd_byte[1:0], rd_byte[1:0], rd_byte[1:0]};  // B8

    reg [23:0] rgb_r;
    reg        de_d1, hs_d1, vs_d1;
    reg        de_d2, hs_d2, vs_d2;

    always @(posedge video_clk or posedge rst_all) begin
        if (rst_all) begin
            rgb_r <= 24'd0;
            de_d1 <= 1'b0; hs_d1 <= 1'b0; vs_d1 <= 1'b0;
            de_d2 <= 1'b0; hs_d2 <= 1'b0; vs_d2 <= 1'b0;
        end else begin
            rgb_r <= rgb_now;
            de_d1 <= de;  hs_d1 <= hs;  vs_d1 <= vs;
            de_d2 <= de_d1; hs_d2 <= hs_d1; vs_d2 <= vs_d1;
        end
    end

    // 首图提交前保持黑屏（与原例程一致）
    wire [23:0] vout = display_valid ? rgb_r : 24'd0;

    // ================= RGB/DE/VS → AXI-Stream =================
    wire        axis_s_user;
    wire        axis_s_valid;
    wire        axis_s_last;
    wire [23:0] axis_s_data;
    wire        axis_s_ready;

    video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480 (
        .I_clk         (video_clk),
        .I_rst         (rst_all),
        .I_vs          (vs_d2),
        .I_de          (de_d2),
        .I_rgb         (vout),
        .O_video_user  (axis_s_user),
        .O_video_valid (axis_s_valid),
        .O_video_last  (axis_s_last),
        .O_video_data  (axis_s_data)
    );

    // ================= EDID 读取触发 =================
    wire edid_trig;
    wire edid_valid;
    wire [7:0] edid_data;

    startup_pulse #(
        .CNT_MAX (20'd100000)
    ) u_startup_pulse (
        .I_clk   (video_clk),
        .I_rst   (rst_all),
        .O_pulse (edid_trig)
    );

    // ================= HDMI 1.4b 发射（参数与原例程逐项一致） =================
    wire [9:0] tmds_ch0_data;
    wire [9:0] tmds_ch1_data;
    wire [9:0] tmds_ch2_data;
    wire [9:0] tmds_clk_data;

    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE            ( "EG"       ),
        .HTOTAL            ( 800        ),
        .HSA               ( 96         ),
        .HFP               ( 16         ),
        .HBP               ( 48         ),
        .HACTIVE           ( 640        ),
        .VTOTAL            ( 525        ),
        .VSA               ( 2          ),
        .VFP               ( 10         ),
        .VBP               ( 33         ),
        .VACTIVE           ( 480        ),
        .VIDEO_VIC         ( 1          ),
        .VIDEO_TPG         ( "Disable"  ),
        .VIDEO_FORMAT      ( "RGB"      ),
        .AUDIO_SAMPLE_RATE ( "48K"      ),
        .IIC_SCL_DIV       ( 250        )
    ) u_hdmi_1_4b_transmitter_core_wrapper (
        .I_pixel_clk        (video_clk),
        .I_rst              (rst_all),
        .I_edid_read_trig   (edid_trig),
        .O_edid_read_valid  (edid_valid),
        .O_edid_read_data   (edid_data),

        .I_axis_s_user      (axis_s_user),
        .I_axis_s_valid     (axis_s_valid),
        .I_axis_s_last      (axis_s_last),
        .I_axis_s_data      (axis_s_data),
        .O_axis_s_ready     (axis_s_ready),

        .I_audio_valid      (1'b0),
        .I_audio_left_data  (24'd0),
        .I_audio_right_data (24'd0),
        .I_acr_valid        (1'b0),
        .I_acr_cts          (20'd0),
        .I_acr_n            (20'd0),

        .O_video_locked     (),
        .O_ddc_scl          (HDMI_DDC_SCL),
        .IO_ddc_sda         (HDMI_DDC_SDA),

        .O_ch0_tmds_data    (tmds_ch0_data),
        .O_ch1_tmds_data    (tmds_ch1_data),
        .O_ch2_tmds_data    (tmds_ch2_data),
        .O_clk_tmds_data    (tmds_clk_data)
    );

    hdmi_phy_wrapper #(
        .DEVICE ( "EG" )
    ) u_hdmi2phy_wrapper (
        .I_pixel_clk        (video_clk),
        .I_serial_clk       (hdmi_5x_clk),
        .I_rst              (rst_all),
        .I_tmds_channel_0   (tmds_ch0_data),
        .I_tmds_channel_1   (tmds_ch1_data),
        .I_tmds_channel_2   (tmds_ch2_data),
        .I_tmds_channel_clk (tmds_clk_data),
        .O_tmds_ch0_p       (HDMI_D0_P),
        .O_tmds_ch1_p       (HDMI_D1_P),
        .O_tmds_ch2_p       (HDMI_D2_P),
        .O_tmds_clk_p       (HDMI_CLK_P)
    );

    // ================= 数码管：最右一位显示 state_code =================
    wire [6:0] seg_code;

    seg_decoder seg_decoder_m0 (
        .bin_data (state_code),
        .seg_data (seg_code)
    );

    seg_scan seg_scan_m0 (
        .clk        (clk),
        .rst_n      (rst_n),
        .seg_sel    (seg_sel),
        .seg_data   (seg_data),
        .seg_data_0 ({1'b1, 7'b111_1111}),
        .seg_data_1 ({1'b1, 7'b111_1111}),
        .seg_data_2 ({1'b1, 7'b111_1111}),
        .seg_data_3 ({1'b1, 7'b111_1111}),
        .seg_data_4 ({1'b1, 7'b111_1111}),
        .seg_data_5 ({1'b1, seg_code})
    );

endmodule
