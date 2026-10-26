// ---------------------------------------------------------------------------
//  诊断顶层 M：横向偏移"粗扫"（步长 40 像素，覆盖半行）
//
//  画面每秒自动换一档，共 16 档（数码管最右一位显示档位 0..9,a..f）：
//      档位 n 对应的环移量 = (n - 8) * 40 像素
//      档位 8 = 0 像素；档位 0 = −320；档位 15 = +280
//  **哪一档图像左右对齐了就记下那一档的数字**，真实偏移就在该档 ±20 像素内，
//  然后我用步长 1（细扫 ±8）或直接按算出的值固化。
//  正常工程不使用本文件。
// ---------------------------------------------------------------------------
module top_hdmi_bmp_coarse (
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
        .ROTSWEEP       (1'b1),
        .ROT_SWEEP_STEP (10'd40),
        .SEGCNT         (1'b1)
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
