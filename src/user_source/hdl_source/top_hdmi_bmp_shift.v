// ---------------------------------------------------------------------------
//  诊断顶层 L：把画面整体"往右挪 1/4 行"（top_hdmi_bmp + ROT_PX=+160）
//
//  用途：板级反馈"图像横向偏移，大约差了四分之一"。本 bit 固定把每行收到的像素
//    环移 +160（= 640 的四分之一）后再上屏，用来验证这个偏移量对不对：
//      · 换这个 bit 后图像位置正确 ⇒ 偏移就是 +160 像素，把这个值固化进正式版；
//      · 还差一点 ⇒ 我用 `wrrot.bit` 的细扫（±15 像素）或再出几档（±40/±80）逼近。
//
//  正常工程不使用本文件，只用于生成对照 bit。
// ---------------------------------------------------------------------------
module top_hdmi_bmp_shift (
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
        .ROT_PX (11'sd160)
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
