// ---------------------------------------------------------------------------
//  诊断顶层 K：R/B 互换对照（top_hdmi_bmp + RGB_SWAP=1）
//
//  用途：板级反馈"图片里的红色显示成蓝色"。本 bit 在送 HDMI 之前把 R/B 互换。
//    换这个 bit 后如果颜色正常了 => 是显示端/HDMI 数据格式的约定问题，改这个开关即可；
//    如果还是不对 => 卡里的 BMP 本身不是标准 BMP（用 doc/convert 的工具重新转一遍）。
//
//  正常工程不使用本文件，只用于生成对照 bit。
// ---------------------------------------------------------------------------
module top_hdmi_bmp_swap (
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
        .RGB_SWAP (1'b1)
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
