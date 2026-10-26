// ---------------------------------------------------------------------------
//  板级自检顶层 C：写回读判别（向 SDRAM 写一整屏纯红）
//
//  = top_hdmi_bmp(.SELFTEST(1'b1), .SOLID(1'b1))
//  即：不读 SD 卡，由计数器向 BUF0 的 307200 个字全部写 0x00FF0000（纯红），
//  然后显示 BUF0。
//
//    ★ 屏幕变成整屏纯红   -> SDRAM 的「写」确实落进去了，读写都正常，
//                            那么问题只在 SD 卡读取侧。
//    ★ 屏幕还是那幅固定噪点 -> SDRAM 的「写」根本没生效（写请求没被 IP 接受 /
//                            地址或掩码不对），显示的一直是 SDRAM 上电内容。
//                            这正好解释「渐变图和真实图片显示出来一模一样」。
// ---------------------------------------------------------------------------
module top_hdmi_bmp_solid (
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
        .SOLID   (1'b1)
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
//  板级自检顶层 E：连续突发写（对照"孤立单拍写"）
//
//  = top_hdmi_bmp(.SELFTEST(1'b1), .SOLID(1'b1), .BURST(1'b1))
//  同样向 BUF0 的 307200 个字全写纯红，但 App_wr_en 是**连续 256 拍拉高**
//  （地址逐拍自增），然后断开 4 拍再做下一批 —— 与厂商 frame_fifo_write 的
//  写法一致，而不是本设计原来的"孤立单拍写"。
//
//    ★ 屏幕变红   -> 真 IP 要求写必须成突发，孤立单拍写会被丢弃。这是根因，
//                    我把正式写通路改成攒够一批再突发写。
//    ★ 仍是噪点   -> 突发也不是关键，下一步查 Sdr_busy 反压与地址映射。
// ---------------------------------------------------------------------------
module top_hdmi_bmp_burst (
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
        .SOLID   (1'b1),
        .BURST   (1'b1)
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
