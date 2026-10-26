// ---------------------------------------------------------------------------
//  诊断顶层 I：数码管版状态仪表（top_hdmi_bmp + SEGCNT=1）
//
//  只做一件事：把 top_hdmi_bmp 的 SEGCNT 参数置 1 —— 除 state_code 外，
//  再显示 3 位十六进制计数，用来一眼看出"按了 K2 之后到底卡在哪一步"：
//
//    第 4 位 load_cnt   ：发起过几次整帧加载（write_req 上升沿次数）
//    第 3 位 commit_cnt ：提交过几次（disp_buf_idx 真的变过几次）
//    第 2 位 word_hi    ：本帧已送进 FIFO 的字数高位（整帧 307200 => 9；送一半 => 4）
//
//  判读（按一次 KEY2）：
//    load+1 & commit+1 & word_hi=9  -> 整链正常，问题在显示/图像内容
//    load+1 & commit 不变           -> 写侧没提交（看 SD 流是否 word_hi=9）
//    load+1 & word_hi 远小于 9      -> SD 流中途断了（1 秒超时会释放）
//    load 不变                      -> 按键/加载没发起
//  换图/轮播同理：每成功换一张，load 和 commit 都应同步 +1。
//
//  正常工程不使用本文件（它不在正常构建的顶层里），只用于生成诊断 bit。
// ---------------------------------------------------------------------------
module top_hdmi_bmp_segcnt (
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
        .SEGCNT (1'b1),
        .RGB_ROT(1'b0)
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
