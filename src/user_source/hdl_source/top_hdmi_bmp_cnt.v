// ---------------------------------------------------------------------------
//  诊断顶层 G：整屏颜色报告"上电扫描到几张 BMP"
//
//  = top_hdmi_bmp(.CNT(1'b1))，不读按键、不改变正常时序。
//
//     红 #FF0000 = 扫到 0 张
//     橙 #FF8000 = 扫到 1 张  <- 这时按 K2 只会在第 0 张上打转、K4 完全没反应
//     黄 #FFFF00 = 扫到 2 张  <- 按 K2 应能换图、K4 应能轮播
//     绿 #00FF00 = 扫到 3 张及以上
//
//  用途：一次性确认"按 K2 画面不变 / K4 没反应"到底是不是因为只扫到 1 张图。
// ---------------------------------------------------------------------------
module top_hdmi_bmp_cnt (
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
        .CNT(1'b1)
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
