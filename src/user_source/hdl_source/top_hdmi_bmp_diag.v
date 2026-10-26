// ---------------------------------------------------------------------------
//  板级诊断顶层 D：整屏纯色报告「读通路卡在哪一步」
//
//  = top_hdmi_bmp(.SELFTEST(1'b1), .DIAG(1'b1))
//  即：同时对 SDRAM 灌渐变图（不需要 SD 卡），但屏幕上不显示图，而是显示一个纯色：
//
//     红  #FF0000  Sdr_init_done 一直没起来     -> SDRAM 初始化 / 时钟 / IP 侧
//     橙  #FF8000  初始化好了，但读 FSM 从没启动 -> 触发链（line_tog / frame_tog）
//     黄  #FFFF00  读启动了，但一行都没收满      -> SDRAM 读握手 / 地址 / 返回数据
//     绿  #00FF00  至少收满过一整行              -> 读通路是通的，问题在别处
//
//  它同时验证「设计是活的」（只要不是花屏，说明 HDMI 与逻辑都在跑）。
// ---------------------------------------------------------------------------
module top_hdmi_bmp_diag (
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
        .SELFTEST(1'b1),
        .DIAG    (1'b1)
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
