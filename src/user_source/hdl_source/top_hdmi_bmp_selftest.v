// ---------------------------------------------------------------------------
//  板级自检顶层 top_hdmi_bmp_selftest
//
//  只做一件事：把 top_hdmi_bmp 的 SELFTEST 参数置 1。
//
//  现象与判定：
//    SELFTEST=1 时完全不读 SD 卡（按键也不用按）。SDRAM 初始化完成后，
//    my_sdram_frame 直接由坐标计数器向 BUF0 写入 307200 个字：
//        R = x[7:0]、G = y[7:0]、B = 0x40   （一幅从左到右、从上到下变化的渐变图）
//    然后一直显示 BUF0。
//
//    ★ 显示器上出现这幅渐变图  -> SDRAM 写 + SDRAM 读 + 行缓存 + HDMI 全链路正常，
//                                 故障一定在「SD 卡读取侧」（卡/座/SPI/扫描）。
//    ★ 显示器上仍是花屏/黑屏    -> 故障在「SDRAM 或显示侧」，
//                                 与 SD 卡、与 bmp 文件无关。
//
//  正常工程不使用本文件（它不在正常构建的顶层里），只用于生成诊断 bit。
// ---------------------------------------------------------------------------
module top_hdmi_bmp_selftest (
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
        .SELFTEST(1'b1)
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


// ---------------------------------------------------------------------------
//  板级自检顶层 B：彩条
//
//  完全不使用 SDRAM、不读 SD 卡，直接在视频域生成 5 条 128 像素宽的竖条
//  （白/黄/青/绿/品红）。它只检验「视频时序 + HDMI PHY + 显示器」这一段。
//
//    ★ 出现整齐的 5 条彩条  -> HDMI 时序与 PHY 正常，问题在 SDRAM 侧。
//    ★ 仍是花屏/黑屏       -> 问题在视频时序或 HDMI 链路（与 SDRAM/SD 无关）。
// ---------------------------------------------------------------------------
module top_hdmi_bmp_bars (
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
        .SELFTEST(1'b0),
        .BARS    (1'b1)
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
