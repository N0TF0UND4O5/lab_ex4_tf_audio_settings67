// ---------------------------------------------------------------------------
//  诊断顶层 H：报告"提交的缓冲区"与"显示实际在读的缓冲区"是否一致
//
//  = top_hdmi_bmp(.BUFCHK(1'b1))
//
//  这两个信号的含义：
//    disp_buf_idx = sd_card_bmp 提交的"当前图片所在缓冲区"（相当于"我换了图"）
//    rd_sel_v     = my_sdram_frame 显示侧真正在用的缓冲区（相当于"我显示的是哪块"）
//
//  整屏颜色 = {disp_buf_idx[0], rd_sel_v}：
//    红 (00) 提交 0 / 显示 0  一致
//    黄 (01) 提交 0 / 显示 1  不一致
//    橙 (10) 提交 1 / 显示 0  提交发生了但显示没跟着切
//    绿 (11) 提交 1 / 显示 1  一致
//
//  按 K2 的判读：
//    * 一直红          -> 提交根本没发生（要查 write_finish_toggle 握手）
//    * 红 -> 橙 -> 红  -> 提交发生了，但显示侧没跟着切（要查 rd_sel_v / rf_base 锁存）
//    * 红 -> 绿        -> 两端都切了；画面还不变就说明两块缓冲区内容一样或没写进去
// ---------------------------------------------------------------------------
module top_hdmi_bmp_bufchk (
    input                       clk,
    input                       rst_n,
    input                       key1,
    input                       key2,

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
    top_hdmi_bmp #(
        .BUFCHK(1'b1)
    ) u_top (
        .clk            (clk),
        .rst_n          (rst_n),
        .key1           (key1),
        .key2           (key2),
        .seg_sel        (seg_sel),
        .seg_data       (seg_data),
        .HDMI_CLK_P     (HDMI_CLK_P),
        .HDMI_D2_P      (HDMI_D2_P),
        .HDMI_D1_P      (HDMI_D1_P),
        .HDMI_D0_P      (HDMI_D0_P),
        .HDMI_DDC_SCL   (HDMI_DDC_SCL),
        .HDMI_DDC_SDA   (HDMI_DDC_SDA),
        .sd_ncs         (sd_ncs),
        .sd_dclk        (sd_dclk),
        .sd_mosi        (sd_mosi),
        .sd_miso        (sd_miso)
    );
endmodule
