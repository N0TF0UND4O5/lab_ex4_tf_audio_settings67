// ---------------------------------------------------------------------------
//  诊断顶层 J：横向环移扫描 + 取头字节/扇区仪表（top_hdmi_bmp + ROTSWEEP=1 + SEGCNT=1）
//
//  用途一（画面"横向错开"）：把每行收到的像素整体环移 rot 个像素再上屏，
//  rot 每秒 +1、在 -15..+15 之间循环。**盯着画面看哪一秒图像左右对齐了**，
//  记下那一刻数码管最右一位的数字即是位移量：
//      0..9 => 0..+9 像素；a..f => -6..-1（4 位补码：f=-1, e=-2, d=-3, c=-4, b=-5, a=-6）
//
//  用途二（第二张图加载不上）：左边 5 位显示
//      [扇区高][扇区中][扇区低]['M'?]['B'?]
//  即"本次加载的目标扇区（十六进制低 3 位）"和"取头读回来的头两字节是不是 'B','M'"。
//  正常应是 4 2；若是 0 0，说明那一次扇区读回来的数据根本不是 BMP 头。
//
//  正常工程不使用本文件，只用于生成诊断 bit。
// ---------------------------------------------------------------------------
module top_hdmi_bmp_rot (
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
        .SEGCNT   (1'b1),
        .ROTSWEEP (1'b1)
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
