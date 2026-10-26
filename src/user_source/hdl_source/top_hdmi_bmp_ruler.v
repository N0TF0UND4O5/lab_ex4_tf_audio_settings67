// ---------------------------------------------------------------------------
//  诊断顶层 M：横向偏移/丢字的"标尺"（top_hdmi_bmp + RULER=1）
//
//  为什么要它：板级一直反馈"图像横向有偏移"，但只靠肉眼估量没法区分下面两种
//  完全不同的成因 —— 前者能在 FPGA 里修，后者只能调显示器：
//    (甲) 数据流本身错位（写通路丢字/重字）→ 图像被剪切，每行错开量还不一样；
//    (乙) 整幅画面在屏幕上平移（显示器缩放/相位问题）→ 图像本身是完整的。
//
//  做法（纯计算，不需要任何人去"估"偏移值）：
//    在【写侧】按"源字序号"给图像打标 ——
//      · 源图第 0 列（源字 0）      → 纯绿竖线
//      · 之后每 64 个源字           → 纯红竖线（1 像素宽）
//    刻度是按"源字序号"打的，而写地址是按"写次数"推进的，所以：
//      · 若 1:1 不错位 → 屏幕上红刻度严格等间距。
//        640x480 送进 1920x1080 屏，水平放大 3 倍 ⇒ 相邻红刻度间隔 = 64x3 = 192 像素，
//        一屏 10 根，位置 x = 0,192,384,...,1728（以源图左边界为 0 计）。
//      · 若写通路丢字/重字 → 刻度立刻疏密不均，能直接看出丢在第几列、丢了多少。
//      · 绿线的绝对位置 = "源图第 0 列"落在屏幕的哪个像素 —— 这就是要算的绘制起点。
//
//  判读方法：拍照后量"绿线到图像左边界"和"相邻红刻度间距"两个数即可，
//  两个数一对比就能唯一确定是(甲)还是(乙)。
//
//  正常工程不使用本文件，只用于生成对照 bit。
// ---------------------------------------------------------------------------
module top_hdmi_bmp_ruler (
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
        .RULER (1'b1)
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
