// ============================================================================
//  top_hdmi_bmp.v —— SD卡两张 640x480 BMP → SDRAM → HDMI 切换显示（自建工程）
//
//  需求：循环读取 SD 卡中的两张 640x480 BMP，存入 SDRAM，HDMI 切换显示。
//        KEY2 读取/搜索下一张；KEY4 自动轮播；首图完成前保持黑屏。
//
//  ── 为什么不会撕裂 ──────────────────────────────────────────────────────
//   原例程撕裂根因（工程文档第 236 行）：显示读与图像写共用同一缓冲区，
//   靠仲裁 + 固定 21 拍延迟补偿硬扛；「写事务优先于读事务」+「新请求会清空 FIFO」
//   导致显示读被读空 → 稳定撕裂。
//
//   本设计三条铁律：
//     (1) 显示 A 时只写 B：两块固定缓冲区，永远不写正在显示的那块。
//     (2) 双行缓存 + 行号最低位选 bank：行 L 显示时预取行 L+1 到另一 bank；
//         bank(L+1)=bank(L-1)，而行 L+1 的预取只在行 L 开始时启动，
//         此刻行 L-1 恰好显示完毕 → 天然错开，永不冲突。
//         取一行 640 字约 5~6us，行周期 32us，余量近 6 倍
//         → 写侧抢占/延迟多少都不影响画面。
//     (3) SDRAM 仲裁读侧优先（写侧平均只需 ~3% 带宽，余量 40 倍）
//         → 显示读的时间可预测，不依赖时序巧合。
//
//  ── 本轮修订（上一版遗留 a~d 项）─────────────────────────────────────────
//     (a) line_tog / frame_tog 已作为端口接入顶层（含 2 拍同步 + 边沿检测）
//     (b) 读侧改为读「正在显示的那张图」的缓冲区：disp_buf_idx 经 2 拍同步后
//         作为电平使用，并**在每次取行的行首锁存进 rf_base**（保证一行之内
//         基准不变 → 换图绝不会撕到行中间）
//     (c) 写侧"新帧开始"用 toggle、"目标缓冲区"用**慢变化电平 + 深一级同步链**，
//         在 mem_clk 域按行首/帧首事件锁存
//     (d) 修复异步 FIFO 读延迟 off-by-one：改为「先弹 FIFO → 下一拍再写 SDRAM」
//         的两态握手（每字 2 拍，@125MHz = 62M 字/秒，仍有 40 倍余量）
//     (f) 读 FSM 改为 RF_IDLE → RF_REQ(发完 640 个请求) → RF_WAIT(等数据收齐，
//         按行缓存写指针计数)，语义明确、不提前返回
//
//  ── 复用（官方已验证，一行未改）─────────────────────────────────────────
//     sd_card_top / sd_card_sec_read_write / sd_card_cmd / spi_master
//     bmp_read（含"每扇区清头字段"修复）/ sd_card_bmp（改加载触发，见文件末尾）
//     sdram / sys_pll / video_pll / startup_pulse / seg_decoder / seg_scan
//     video_rgb_to_axis_640x480 / hdmi_1_4b_transmitter_core_wrapper / hdmi_phy_wrapper
//
//  ── 自写 ────────────────────────────────────────────────────────────────
//     my_video_timing / afifo_32_256 / my_sdram_frame / top_hdmi_bmp
//
//  ── 明确不用 ────────────────────────────────────────────────────────────
//     frame_read_write / frame_fifo_write / frame_fifo_read /
//     video_delay / color_bar / video_timing_data
//
//  ⚠ 仍未做仿真验证。上板前先跑：
//     iverilog -t null -g2005 -Wall -I <SD目录> -o NUL top_hdmi_bmp.v <各子模块>
// ============================================================================
`timescale 1ns/1ps


// ---------------------------------------------------------------------------
// 1) 视频时序 640x480@60（800x525），负极性同步
// ---------------------------------------------------------------------------
module my_video_timing #(
    parameter H_ACTIVE = 640, H_FP = 16, H_SYNC = 96, H_BP = 48,
    parameter V_ACTIVE = 480, V_FP = 10, V_SYNC = 2,  V_BP = 33
)(
    input             clk,
    input             rst,
    output reg        hs,
    output reg        vs,
    output reg        de,
    output     [9:0]  x,
    output     [9:0]  y,
    output reg        line_tog,
    output reg        frame_tog
);
    localparam H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
    localparam V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

    reg [9:0] hcnt, vcnt;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hcnt <= 10'd0; vcnt <= 10'd0;
        end else if (hcnt == H_TOTAL - 1) begin
            hcnt <= 10'd0;
            vcnt <= (vcnt == V_TOTAL - 1) ? 10'd0 : (vcnt + 10'd1);
        end else begin
            hcnt <= hcnt + 10'd1;
        end
    end

    assign x = hcnt;
    assign y = vcnt;

    wire h_sync_on = (hcnt >= H_ACTIVE + H_FP) && (hcnt < H_ACTIVE + H_FP + H_SYNC);
    wire v_sync_on = (vcnt >= V_ACTIVE + V_FP) && (vcnt < V_ACTIVE + V_FP + V_SYNC);

    always @(posedge clk or posedge rst) begin
        if (rst) begin hs <= 1'b1; vs <= 1'b1; de <= 1'b0; end
        else begin
            hs <= ~h_sync_on;
            vs <= ~v_sync_on;
            de <= (hcnt < H_ACTIVE) && (vcnt < V_ACTIVE);
        end
    end

    reg de_d;
    always @(posedge clk or posedge rst) begin
        if (rst) begin de_d <= 1'b0; line_tog <= 1'b0; frame_tog <= 1'b0; end
        else begin
            de_d <= de;
            if (de && !de_d) line_tog <= ~line_tog;               // 有效行起始
            if ((vcnt == V_ACTIVE + V_FP) && (hcnt == 0)) frame_tog <= ~frame_tog;
        end
    end
endmodule


// ---------------------------------------------------------------------------
// 2) 自写异步 FIFO：32bit x 256（灰度码指针）
//    rd_en 后数据在**下一拍**出现在 dout —— 使用方必须遵守（见写侧对齐推导）
//
//    【为什么从 64 深改成 256 深 —— 这是本轮最关键的改动】
//      板级现象"正式流程的加载→提交始终不发生（黑屏、disp_buf_idx 恒 0）"的根因是
//      **写 FIFO 溢出丢字**：
//        · 写侧一次突发必须"连续多拍 App_wr_en"，且启动条件里有 rf_state == RF_IDLE
//          （不能打断在途读事务，见 3.4/3.5），所以最坏要等一整行取数
//          （实测 3041 拍 @125MHz ≈ 24us，行周期 32us）；
//        · 而 SD 侧（bmp_read）对 FIFO 的 full **一无所知（没有反压）**，
//          在这段等待里照样 1 字/us 地往 FIFO 里灌；
//        · 原来的触发条件是"等 FIFO **满**（64 字）"，于是 FIFO 一旦满，
//          后面来的字全部被**静默丢弃**（afifo 里 `wr_en && !full` 直接丢掉）；
//        · 一帧必须正好 307200 字（4800×64）才能凑满最后一次突发，
//          只要丢过 1 个字，wr_word_cnt 永远到不了 307199
//          → write_finish_toggle 永不翻转 → sd_card_bmp 永不提交 → 黑屏。
//      64 深时"满"= 0 字余量，必然丢字（仿真已复现：307200 字只落盘 302464）。
//      256 深 + 写侧"半满（128 字）就突发" => 余量 128 字 ≈ 123us 生产时间，
//      是最坏等待（24~30us）的 4 倍以上，从设计上杜绝丢字。
//    rd_used / rd_wptr：给写侧判断"现在能连续取多少字"（决定突发长度），
//      同步链滞后 => 只会**低估**占用 => 绝不会弹空（安全方向）。
// ---------------------------------------------------------------------------
module afifo_32_256 (
    input               wr_clk,
    input               wr_rst,
    input               wr_en,
    input  [31:0]       din,
    output              full,
    output [8:0]        wr_used,

    input               rd_clk,
    input               rd_rst,
    input               rd_en,
    output reg [31:0]   dout,
    output              empty,
    output [8:0]        rd_used,
    output [8:0]        rd_wptr
);
    reg [31:0] mem [0:255];
    reg [8:0]  wbin, wgray, rbin, rgray;
    reg [8:0]  wgray_s1, wgray_s2, rgray_s1, rgray_s2;
    reg [8:0]  rd_wptr_r;

    wire [8:0] wbin_nxt  = wbin + 9'd1;
    wire [8:0] wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;
    wire [8:0] rbin_nxt  = rbin + 9'd1;
    wire [8:0] rgray_nxt = (rbin_nxt >> 1) ^ rbin_nxt;

    function [8:0] gray2bin;
        input [8:0] g;
        integer k;
        begin
            gray2bin[8] = g[8];
            for (k = 7; k >= 0; k = k - 1)
                gray2bin[k] = gray2bin[k+1] ^ g[k];
        end
    endfunction

    always @(posedge wr_clk or posedge wr_rst) begin
        if (wr_rst) begin wbin <= 9'd0; wgray <= 9'd0; end
        else if (wr_en && !full) begin
            mem[wbin[7:0]] <= din;
            wbin  <= wbin_nxt;
            wgray <= wgray_nxt;
        end
    end
    always @(posedge wr_clk or posedge wr_rst) begin
        if (wr_rst) begin rgray_s1 <= 9'd0; rgray_s2 <= 9'd0; end
        else begin rgray_s1 <= rgray; rgray_s2 <= rgray_s1; end
    end
    assign full    = (wgray_nxt == {~rgray_s2[8:7], rgray_s2[6:0]});
    assign wr_used = wbin - gray2bin(rgray_s2);

    always @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst) begin rbin <= 9'd0; rgray <= 9'd0; dout <= 32'd0; end
        else if (rd_en && !empty) begin
            dout  <= mem[rbin[7:0]];
            rbin  <= rbin_nxt;
            rgray <= rgray_nxt;
        end
    end
    always @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst) begin wgray_s1 <= 9'd0; wgray_s2 <= 9'd0; end
        else begin wgray_s1 <= wgray; wgray_s2 <= wgray_s1; end
    end
    assign empty   = (rgray == wgray_s2);
    // 占用换算打成一级寄存器：gray2bin 是 9 级异或链，直接组合出去会让关键路径变长
    // （实测 WNS 从 8.3ns 掉到 5.3ns）。多延迟一拍对"能不能连续取 128 字"的判断无影响
    // （只是把占用估得更保守一点，安全方向）。
    always @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst) rd_wptr_r <= 9'd0;
        else        rd_wptr_r <= gray2bin(wgray_s2);
    end
    assign rd_wptr = rd_wptr_r;
    assign rd_used = rd_wptr_r - rbin;
endmodule


// ---------------------------------------------------------------------------
// 3) SDRAM 读写控制 + 双行缓存
// ---------------------------------------------------------------------------
module my_sdram_frame #(
    parameter H_ACTIVE = 640,
    parameter V_ACTIVE = 480,
    // 一帧的字数（640*480 = 307200）。参数化只是为了"小帧快速仿真"，
    // 板上构建用默认值，行为与硬编码一致。
    parameter [19:0] FRAME_WORDS = H_ACTIVE * V_ACTIVE,
    // 一次连续突发的字数。必须**连续**拉高 App_wr_en（板级实测：孤立单拍写会被 IP 丢弃），
    // 长度取 4 的倍数（手册 §2.4：数据以 4 个为单位，地址跳跃须为 4 的倍数）。
    parameter [8:0]  WR_BURST_LEN = 9'd128,
    // 写侧垂直翻转：BMP 文件的行序是"自下而上"（文件第 0 行是图像最后一行），
    // 厂商 frame_fifo_write.v 的 WRITE_V_FLIP=1 就是干这个的
    // （VFLIP_FIRST_ADDR_OFFSET=(H-1)*W、VFLIP_LINE_JUMP=W*2-1，行内仍从左到右）。
    // 板级实测：不加翻转时图像上下颠倒。默认打开；若卡里放的是"已经翻转好"的图，
    // 把它改成 1'b0 重新出 bit 即可。
    parameter        WR_VFLIP = 1'b1,
    // 【横向偏移】WR_LEAD = 每帧开头先写多少个"纯黑"字。
    //   板级量出来的值是 **170**（见交接口 §0.0：接缝在源列 470 => 640-470 = 170）。
    //   这些黑字把源端少送的那 170 个位置占掉，于是整幅图不再左移、右边那 170 列
    //   也不再是 SDRAM 残留（"小锯齿"随之消失）。
    //   想微调就只改这一个数字，其它逻辑不用动。
    parameter [9:0] WR_LEAD = 10'd172,
    // 【本轮】0 = 固定用 WR_LEAD(172)；1 = 用源端报出的值。
    //   现在源端走了"取头读复用"：帧首那段来自**通过头部校验的那次读**（必然对齐）
    //   ⇒ 帧首缺字量恒为 0 ⇒ 源端报 0 ⇒ 不补黑，位置与"这次读有没有错位"无关。
    parameter        LEAD_USE_MEAS = 1'b1,
    // 【偏移定标 RULER】在"写侧"给源图的每第 64 个像素打一个纯红刻度、第 0 个打纯绿。
    //   关键：刻度是按【源字序号】(FIFO 弹出的第几个字) 打的，而写地址是按【写次数】推进的。
    //   · 若两者 1:1 不错位，屏幕上红刻度必然等间距（每 64 个显示像素一根，1920 宽屏上是 192 像素）；
    //   · 若写通路丢字/重字，刻度立刻疏密不均 —— 一眼就能看出丢在哪、丢了多少。
    //   · 绿色那根就是"源图第 0 列"落在屏幕上的确切位置，直接量它即可，
    //     不需要任何人去"估"偏移量。
    parameter        RULER = 1'b0,
    // 源端长时间没有新字的兜底（mem_clk 拍数，默认 250ms @125MHz）。
    // 正常流程永远用不到（源端送满 FRAME_WORDS 个字后 wr_busy 会落 0，立刻提交）；
    // 只有"SD 提前结束/中途挂住"时才会走到，用来保证不黑屏。
    parameter [25:0] SRC_STALL_CYCLES = 26'd31_250_000,
    // 【诊断】行内横向环移扫描：把每行收到的数据整体环移 rot_s 个像素再写进行缓存，
    // rot_s 每秒 +1（-15..+15 循环）。板上看画面：哪个数字下图像左右对齐了，
    // 就是"读回来的像素与光栅错开了几个像素"。默认 0 = 完全不影响正常构建。
    parameter        ROTSWEEP = 1'b0,
    // 环移扫描的步长（像素）：扫描 16 档，rot = (档位-8)*步长，
    // 步长 1 => ±8 像素细扫；步长 40 => −320..+280 粗扫（覆盖半行）
    parameter [9:0]  ROT_SWEEP_STEP = 10'd1,
    // 固定行内环移（像素，可为负）：补偿"数据流与光栅错开 K 个像素"
    parameter signed [10:0] ROT_FIX = 11'sd0,
    parameter [26:0] ROT_STEP = 27'd125_000_000,      // 1s @125MHz
    parameter TRANSITIONS = 1'b0,
    parameter USE_EFFECT_CONTROL = 1'b0,
    parameter USE_SOURCE_ORIENTATION=1'b0,
    parameter [20:0] BUF0_ADDR = 21'd0,
    parameter [20:0] BUF1_ADDR = 21'd307200,
    // ---- 板级自检模式（默认 0，对正常设计零影响；综合会把自检逻辑整块剪掉）----
    // 1 = 完全不读 SD 卡：SDRAM 初始化完成后，由坐标计数器直接向 BUF0 写一幅
    //     R=x[7:0]、G=y[7:0]、B=0x40 的渐变图，然后一直显示它。
    // 用途：一次下载就能判定「SDRAM 写 + SDRAM 读 + 显示通路」这一半是否正常，
    //       从而把故障二分为「存储器/显示侧」还是「SD 卡读取侧」。
    parameter        SELFTEST  = 1'b0,
    // 自检时写纯色（SELFTEST 且 ST_SOLID 时写一整屏红）。
    // 用途：判别"写到底有没有落进 SDRAM" —— 若屏幕变成纯红，说明写生效；
    //       若屏幕还是那幅固定噪点，说明写根本没落进 SDRAM。
    parameter        ST_SOLID  = 1'b0,
    // 自检时用"连续突发写"：App_wr_en 连续拉高 256 拍（地址逐拍自增），再断开 4 拍。
    // 对照实验用：厂商 frame_fifo_write 就是这么写的；本设计原来是孤立单拍写。
    // 若开这个开关后屏幕变红，说明真 IP 要求写必须成突发，孤立单拍会被丢弃。
    parameter        ST_BURST  = 1'b0,
    // 自检时同时写两块缓冲区做"到底在读哪一块"的判别：
    //   BUF0（0..307199）      <- 纯红
    //   BUF1（307200..614399） <- 纯绿
    // 屏幕变红 = 显示读 BUF0（正常）；变绿 = 显示读 BUF1（说明 rd_sel_v 反了/恒为 1）；
    // 还是噪点 = 写确实没落进 SDRAM。一次下载就能三分。
    parameter        ST_DUAL   = 1'b0
)(
    input               mem_clk,
    input               rst,
    input [1:0]         effect_i,
    input               source_top_down,

    // ---- SDRAM 用户接口 ----
    input               Sdr_init_done,
    input               Sdr_busy,
    output reg          App_wr_en,
    output reg [20:0]   App_wr_addr,
    output     [3:0]    App_wr_dm,
    output reg [31:0]   App_wr_din,
    output reg          App_rd_en,
    output reg [20:0]   App_rd_addr,
    input               Sdr_rd_en,
    input      [31:0]   Sdr_rd_dout,

    // ---- 板级诊断标志（只给顶层上色/数码管用，正常构建无副作用）----
    output reg          diag_fetch,     // 读 FSM 是否曾经离开过 IDLE
    output reg          diag_line,      // 是否曾经收满过一整行 640 字
    output              diag_rsel,      // 显示侧实际在用的读基准选择（= rd_sel_v）
    output [1:0]        display_buf_ack,
    // 读事务"没能一次凑齐一行"的次数（RF_WAIT 超时重发）。
    //   正常情况下一次取行 = 连发 640 拍、数据逐拍回来 => 永远是 0。
    //   一旦不为 0，说明 IP 在事务中间丢了数据（= 板级竖条/横条的直接证据）。
    output reg [3:0]    diag_to_cnt,    // 饱和计数 0..15
    output      [3:0]   diag_rot,       // 诊断：当前横向环移量（4 位补码，f = -1）
    output      [9:0]   diag_lead,      // 诊断：本帧补黑条数（实测值；0 = 本帧不用补）

    // ---- 写侧（sd_card_clk）----
    input               wr_clk,
    input               write_req,
    output reg          write_req_ack,
    output              wr_source_ready,
    input               write_en,
    input  [31:0]       write_data,
    input  [1:0]        write_buf_idx,
    // ---- 【横向偏移根治】源端实测的"本帧帧首补黑条数"（wr_clk 域，每帧一次）----
    //   wr_lead_words：本帧该补几个纯黑字（由 bmp_read 用"第一个数据扇区实收字节数"算出）
    //   wr_lead_valid：本次加载进入时清 0、第一个数据扇区读完时置 1；写侧靠上升沿取数
    input  [9:0]        wr_lead_words,
    input               wr_lead_valid,
    output reg          write_finish_toggle,

    // ---- 显示缓冲区选择（sd_card_clk，慢变化电平）----
    input  [1:0]        disp_buf_idx,
    input               display_valid_i,

    // ---- 视频侧（video_clk）----
    input               video_clk,
    input               line_tog_i,
    input               frame_tog_i,
    input  [9:0]        line_idx,
    input  [9:0]        pix_idx,
    output [31:0]       pix_data
);
    // Async assertion, memory-clock synchronous release. In particular the
    // inferred line-RAM WEA must not depend combinationally on the50MHz reset.
    reg[2:0]mem_reset_pipe;
    always @(posedge mem_clk or posedge rst)begin
        if(rst)mem_reset_pipe<=3'b111;
        else mem_reset_pipe<={mem_reset_pipe[1:0],1'b0};
    end
    wire mem_reset=mem_reset_pipe[2];
    assign App_wr_dm = 4'b0000;                 // 全字节写

    // =====================================================================
    // 3.1 写侧：FIFO 入队（wr_clk 域）+ 握手 + 帧起始/目标缓冲 toggle
    // =====================================================================
    wire [31:0] fifo_dout;
    wire        fifo_empty;
    wire [8:0]  fifo_rd_used;               // FIFO 里现成可连续取走的字数（保守低估）
    wire [8:0]  fifo_rd_wptr;               // 同步过来的写指针（用于"源端还有没有新字"）
    reg         fifo_re;

    wire fifo_full;
    wire [8:0] fifo_wr_used;
    assign wr_source_ready = !fifo_full && (fifo_wr_used < 9'd192);
    afifo_32_256 u_wrfifo (
        .wr_clk (wr_clk),  .wr_rst (rst || write_req),  .wr_en (write_en && wr_busy), .din (write_data),
        .full (fifo_full), .wr_used (fifo_wr_used),
        .rd_clk (mem_clk), .rd_rst (rst || wr_req_mem[2]),  .rd_en (fifo_re),   .dout (fifo_dout),
        .empty (fifo_empty), .rd_used (fifo_rd_used), .rd_wptr (fifo_rd_wptr)
    );

    reg        wr_busy;
    reg [19:0] wr_pix_cnt;
    reg        wr_start_tgl;                    // 帧起始 toggle（送给 mem 侧）
    reg        wr_flip_source;
    reg[2:0]wr_flip_sync;reg wr_flip_latched;
    always @(posedge wr_clk or posedge rst)begin
        if(rst)wr_flip_source<=WR_VFLIP;else if(write_req)wr_flip_source<=WR_VFLIP&&!(USE_SOURCE_ORIENTATION&&source_top_down);
    end
    always @(posedge mem_clk or posedge mem_reset)begin
        if (mem_reset)begin wr_flip_sync<={3{WR_VFLIP}};wr_flip_latched<=WR_VFLIP;end
        else begin wr_flip_sync<={wr_flip_sync[1:0],wr_flip_source};if(wr_start_p)wr_flip_latched<=wr_flip_sync[2];end
    end
    reg        wr_sel_lvl;                      // 目标缓冲区电平（帧内保持稳定）
    // Hold the source in its request phase until both FIFO domains are cleared.
    reg [2:0] wr_req_mem;
    reg [3:0] wr_clear_cnt;
    reg [1:0] wr_clear_sync;
    reg [1:0] overflow_sync;
    reg wr_overflow;
    wire wr_clear_ready = wr_req_mem[2] && (wr_clear_cnt == 4'd8);
    always @(posedge mem_clk or posedge mem_reset) begin
        if (mem_reset) begin
            wr_req_mem <= 3'd0;
            wr_clear_cnt <= 4'd0;
            overflow_sync <= 2'd0;
        end else begin
            wr_req_mem <= {wr_req_mem[1:0], write_req};
            overflow_sync <= {overflow_sync[0], wr_overflow};
            if (!wr_req_mem[2]) wr_clear_cnt <= 4'd0;
            else if (wr_clear_cnt != 4'd8) wr_clear_cnt <= wr_clear_cnt + 1'b1;
        end
    end
    always @(posedge wr_clk or posedge rst) begin
        if (rst) begin wr_clear_sync <= 2'd0; wr_overflow <= 1'b0; end
        else begin
            wr_clear_sync <= {wr_clear_sync[0], wr_clear_ready};
            if (write_req) wr_overflow <= 1'b0;
            else if (wr_busy && write_en && fifo_full) wr_overflow <= 1'b1;
        end
    end

    always @(posedge wr_clk or posedge rst) begin
        if (rst) begin
            write_req_ack <= 1'b0;
            wr_busy       <= 1'b0;
            wr_pix_cnt    <= 20'd0;
            wr_start_tgl  <= 1'b0;
            wr_sel_lvl    <= 1'b0;
        end else begin
            // 四相握手：req 抬起给 ack；req 撤销 = 本帧开始
            if (write_req) begin
                write_req_ack <= wr_clear_sync[1];
            end else begin
                if (write_req_ack) begin
                    wr_busy      <= 1'b1;
                    wr_pix_cnt   <= 20'd0;
                    wr_start_tgl <= ~wr_start_tgl;      // 通知 mem 侧：新帧开始
                    wr_sel_lvl   <= write_buf_idx[0];   // 锁存目标缓冲区，整帧不变
                end
                write_req_ack <= 1'b0;
            end
            if (wr_busy && write_en) begin
                if (wr_pix_cnt == FRAME_WORDS - 20'd1) wr_busy <= 1'b0;
                else                                   wr_pix_cnt <= wr_pix_cnt + 20'd1;
            end
        end
    end

    // =====================================================================
    // 3.2 跨域同步（wr_clk / video_clk -> mem_clk）
    // =====================================================================
    // 写侧"帧起始"：4 拍同步链取边沿；"目标缓冲区"：3 拍链取电平
    //（多一级是为了让电平在边沿被识别时已经稳定）
    reg [3:0] wr_start_s;
    reg [2:0] wr_sel_s;
    wire      wr_start_p = wr_start_s[3] ^ wr_start_s[2];
    wire      wr_sel_v   = wr_sel_s[2];

    always @(posedge mem_clk or posedge mem_reset) begin
        if (mem_reset) begin
            wr_start_s <= 4'b0000;
            wr_sel_s   <= 3'b000;
        end else begin
            wr_start_s <= {wr_start_s[2:0], wr_start_tgl};
            wr_sel_s   <= {wr_sel_s[1:0],   wr_sel_lvl};
        end
    end

    // 显示缓冲区选择：慢变化电平，2 拍同步即可
    reg [1:0] disp_sel_s;
    wire      rd_sel_v = disp_sel_s[1];
    assign    diag_rsel = rd_sel_v;          // 诊断：显示侧实际在用哪块缓冲区
    assign    diag_lead = lead_q;            // 诊断：本帧的补黑条数（实测）
    always @(posedge mem_clk or posedge mem_reset) begin
        if (mem_reset) disp_sel_s <= 2'b00;
        else     disp_sel_s <= {disp_sel_s[0], disp_buf_idx[0]};
    end

    // 视频侧 toggle -> mem_clk
    reg [2:0] line_tog_s, frame_tog_s;
    always @(posedge mem_clk or posedge mem_reset) begin
        if (mem_reset) begin
            line_tog_s  <= 3'b000;
            frame_tog_s <= 3'b000;
        end else begin
            line_tog_s  <= {line_tog_s[1:0],  line_tog_i};
            frame_tog_s <= {frame_tog_s[1:0], frame_tog_i};
        end
    end
    wire line_tog_p  = line_tog_s[2]  ^ line_tog_s[1];
    wire frame_tog_p = frame_tog_s[2] ^ frame_tog_s[1];

    // =====================================================================
    // 3.2b 源端"本帧已全部送完"检测（决定收尾突发的时机）
    //
    //   wr_clk 域的 wr_busy 在收到第 FRAME_WORDS 个 write_en 后落 0，
    //   即"这一帧的字已经全部进了 FIFO"。同步过来后用于两件事：
    //     ① 收尾：剩下不足一整批（< WR_BURST_LEN）的字也要写出去 ——
    //        否则 FIFO 永远等不到"半满"，最后几个字永远留在 FIFO 里，
    //        wr_word_cnt 到不了 FRAME_WORDS-1 → 提交再次失效；
    //     ② 兜底：源端长时间没有任何新字（SD 提前结束/卡住）时也要收尾提交，
    //        宁可显示一张"不完整但可判读"的图，也不要永远黑屏。
    // =====================================================================
    reg  [3:0]  src_busy_s;
    reg         src_seen;                 // 本帧见过 wr_busy=1（否则复位后 0 会被误判成"已送完"）
    reg  [25:0] src_idle_cnt;
    reg  [8:0]  wptr_sync_d;
    wire        src_busy_v    = src_busy_s[3];
    wire        src_all_sent  = src_seen && !src_busy_v;
    // 停字兜底只认"已经写进去过至少一个字"的情况：
    // 若一个字都没来（例如取头就失败、SD 根本没启动），就不要提交 ——
    // 提交会把 disp_buf_idx 指到一块从没写过的缓冲区，屏幕从"黑"变成"雪花"，
    // 反而让诊断变难。这种情况交给 sd_card_bmp 的 1 秒超时去处理。
    wire        src_stalled   = (src_idle_cnt >= SRC_STALL_CYCLES) && (wr_word_cnt != 20'd0);
    wire        wr_src_done   = src_all_sent || src_stalled;

    always @(posedge mem_clk or posedge mem_reset) begin
        if (mem_reset) begin
            src_busy_s  <= 4'd0;
            src_seen    <= 1'b0;
            src_idle_cnt<= 26'd0;
            wptr_sync_d <= 9'd0;
        end else begin
            src_busy_s <= {src_busy_s[2:0], wr_busy};
            if (wr_start_p) begin
                src_seen     <= 1'b0;
                src_idle_cnt <= 26'd0;
                wptr_sync_d  <= fifo_rd_wptr;
            end else begin
                if (src_busy_v) src_seen <= 1'b1;
                // FIFO 写指针动了 = 源端又送来新字 -> 计时清零
                if (fifo_rd_wptr != wptr_sync_d) begin
                    wptr_sync_d  <= fifo_rd_wptr;
                    src_idle_cnt <= 26'd0;
                end else if (src_idle_cnt < SRC_STALL_CYCLES) begin
                    src_idle_cnt <= src_idle_cnt + 26'd1;
                end
            end
        end
    end

    // =====================================================================
    // 3.3 行缓存：1280x32，bank0=[0:639]（偶数行）bank1=[640:1279]（奇数行）
    //     选择 bank 用的是"行号最低位"，不需要交换逻辑
    // =====================================================================
    reg [31:0] line_mem [0:2*H_ACTIVE-1];
    reg [31:0] line_mem_new [0:2*H_ACTIVE-1];
    reg tr_seen,tr_active,tr_target,tr_effect,tr_next_effect;
    reg[1:0]effect_sync0,effect_sync1;
    always @(posedge mem_clk or posedge mem_reset)begin
        if (mem_reset)begin effect_sync0<=2;effect_sync1<=2;end
        else begin effect_sync0<=effect_i;effect_sync1<=effect_sync0;end
    end
    wire[1:0]chosen_effect=USE_EFFECT_CONTROL?effect_sync1:(tr_next_effect?2'd1:2'd2);

    reg [5:0] tr_step;
    reg [20:0] rf_newbase;
    reg rf_dual,rf_second;
    reg [20:0] rf_line_addr;
    reg [4:0] rf_second_gap;
    reg [1:0] display_valid_sync;
    always @(posedge mem_clk or posedge mem_reset)begin
        if (mem_reset)display_valid_sync<=0;
        else display_valid_sync<={display_valid_sync[0],display_valid_i};
    end
    reg [7:0] tr_sync0,tr_sync1,tr_pixel_ctrl;
    always @(posedge video_clk or posedge rst)begin
        if(rst)begin tr_sync0<=0;tr_sync1<=0;tr_pixel_ctrl<=0;end
        else begin
            tr_sync0<={tr_active,tr_effect,tr_step};tr_sync1<=tr_sync0;tr_pixel_ctrl<=tr_sync1;
        end
    end
    wire [10:0] slide_distance=(tr_sync1[5:0]*H_ACTIVE)>>5;
    wire [10:0] slide_sum={1'b0,pix_idx}+slide_distance;
    wire slide_select=slide_sum>=H_ACTIVE;
    wire [9:0] slide_column=slide_select?(slide_sum-H_ACTIVE):slide_sum;
    wire [9:0] read_column=(TRANSITIONS&&tr_sync1[7]&&tr_sync1[6])?slide_column:pix_idx;
    reg slide_select_q;
    reg [31:0] pix_new_q;
    function [7:0] blend_channel;
        input [7:0] old_c,new_c;input [5:0] weight;
        reg signed [8:0] delta;
        reg signed [15:0] product;
        reg signed [16:0] result;
        begin
            delta=$signed({1'b0,new_c})-$signed({1'b0,old_c});
            product=delta*$signed({1'b0,weight});
            result=$signed({1'b0,old_c,5'b0})+product+17'sd16;
            blend_channel=result[12:5];
        end
    endfunction


    // 视频侧读口（单时钟，1 拍延迟）
    reg [31:0] pix_q;
    always @(posedge video_clk) begin
        pix_q <= line_mem[(line_idx[0] ? H_ACTIVE : 0) + read_column];
        if(TRANSITIONS)pix_new_q <= line_mem_new[(line_idx[0] ? H_ACTIVE : 0) + read_column];
        slide_select_q<=slide_select;
    end
    wire [23:0] fade_rgb={blend_channel(pix_q[31:24],pix_new_q[31:24],tr_pixel_ctrl[5:0]),
                          blend_channel(pix_q[23:16],pix_new_q[23:16],tr_pixel_ctrl[5:0]),
                          blend_channel(pix_q[15:8],pix_new_q[15:8],tr_pixel_ctrl[5:0])};
    assign pix_data = !TRANSITIONS||!tr_pixel_ctrl[7] ? pix_q :
                      tr_pixel_ctrl[6] ? (slide_select_q?pix_new_q:pix_q) : {fade_rgb,8'd0};

    // =====================================================================
    // 3.3b 横向环移扫描（诊断用；ROTSWEEP=0 时 rot_s 恒 0，整块逻辑被剪掉）
    // =====================================================================
    reg signed [10:0] rot_s;
    reg [3:0]        rot_i;                 // 扫描档位 0..15（也是数码管要显示的数）
    reg [26:0]       rot_cnt;
    always @(posedge mem_clk or posedge mem_reset) begin
        if (mem_reset) begin
            rot_i   <= 4'd8;
            rot_s   <= ROT_FIX;
            rot_cnt <= 27'd0;
        end else if (ROTSWEEP) begin
            // rot = (档位-8)*步长：档位 8 表示 0 偏移，0 表示 −8*步长
            rot_s   <= ($signed({7'b0, rot_i}) - 11'sd8) * $signed({1'b0, ROT_SWEEP_STEP});
            if (rot_cnt == ROT_STEP) begin
                rot_cnt <= 27'd0;
                rot_i   <= (rot_i == 4'd15) ? 4'd0 : (rot_i + 4'd1);
            end else begin
                rot_cnt <= rot_cnt + 27'd1;
            end
        end else begin
            rot_s <= ROT_FIX;               // 固定环移（补偿"数据流与光栅错开 K 像素"）
        end
    end
    assign diag_rot = rot_i;                // 扫描时显示"档位"，不是具体像素值

    // 环移后的行内写入下标 = (rf_recv_cnt + rot_s) mod 640
    wire signed [12:0] rot_idx_s   = {3'b000, rf_recv_cnt[9:0]} + {{2{rot_s[10]}}, rot_s};
    wire signed [12:0] rot_idx_neg = rot_idx_s + 13'sd640;
    wire signed [12:0] rot_idx_pos = rot_idx_s - 13'sd640;
    wire        [9:0]  rot_idx = (rot_idx_s < 13'sd0)    ? rot_idx_neg[9:0] :
                                 (rot_idx_s > 13'sd639)  ? rot_idx_pos[9:0] :
                                                           rot_idx_s[9:0];

    // =====================================================================
    // 3.4 预取 FSM（mem_clk）：每次触发取一整行 640 字
    //     触发源 = 帧起始 toggle 边沿（取第 0 行）或行起始 toggle 边沿（取下一行）
    // =====================================================================
    localparam RF_IDLE = 3'd0, RF_REQ = 3'd1, RF_WAIT = 3'd2, RF_SETUP=3'd3, RF_SECOND=3'd4;

    // 一次取一行的请求节奏。
    //
    // 【本轮修正（板级：画面竖条 + 横向条纹）】
    //   原来 RD_BURST_MAX = 256，且中途会因为 Sdr_busy 拉低 App_rd_en。
    //   但厂商代码 frame_fifo_read.v 的节奏是：连发 BURST_SIZE 拍读使能后，
    //   **必须等满 10 拍**（`rd_burst_finish = rd_vld && rd_delay==10`）确认数据全部排空，
    //   才允许开下一次突发 —— 即"数据传输期间绝不能出现空隙"。
    //   本模块原来在行中间插 1 拍空隙（每 256 拍一次），任何一次空隙都可能让 IP
    //   结束/清空当前事务、丢掉在途的约 10 个字，于是行内每 256 像素出现一次错位
    //   （板上就是 x≈256/512 处的竖条 + 行尾横条）。
    //   现在：**一整行的 640 个字一次连续读完，中途不插任何空隙**；
    //   Sdr_busy 只在"开始取这一行之前"判断（手册 §7 注意 3 的字面意思：每次读写操作**前**判断），
    //   不打断已经开始的读事务。
    localparam RD_BURST_MAX   = 11'd1024;   // 必须 > H_ACTIVE，保证行内不出现空隙
    // 等数据兜底超时（mem_clk 拍数）：约 16us @125MHz，比一整行周期还长，正常永远到不了。
    localparam RD_WAIT_TIMEOUT= 16'd2000;

    reg [2:0]  rf_state;
    reg [15:0] rf_fill_line;                 // 本次要取的行号
    reg [15:0] rf_active_line;               // immutable for the active read transaction
    reg [10:0] rf_req_cnt;                   // 已发出的请求数
    reg [10:0] rf_recv_cnt;                  // 已收到的数据数
    reg [20:0] rf_base;                      // 【本轮修订(b)】行首锁存的读基准
    assign display_buf_ack = {1'b0, (rf_base == BUF1_ADDR)};
    reg        rf_start;
    // 【重要】取行请求必须"可挂起"：写突发期间读侧被禁止发请求，
    // 如果触发只是单拍脉冲就会被吃掉，读 FSM 永远不启动 -> 行缓存全 0 -> 黑屏。
    reg        rf_pending;
    // 【重要】显示缓冲区选择必须"每帧锁存一次"：原来是在每行取数时锁存 rf_base，
    // 如果 sd_card_bmp 在帧中途提交新图（disp_buf_idx 变化），
    // 下半帧就会从另一块缓冲区读 -> 画面从某一行起变成另一张图 = 撕裂。
    // 改成在 frame_tog 处锁存，一帧之内恒定。
    reg        frame_sel;
    reg [10:0] rf_burst_cnt;                 // 本次事务内已连发的请求数
    reg [15:0] rf_wait_cnt;                  // RF_WAIT 内的等待计时（兜底重发用）

    always @(posedge mem_clk or posedge mem_reset) begin
        if (mem_reset) begin
            // 注意：rf_state 只由下面 3.4 的读 FSM 那一个 always 块驱动
            // （TD 不允许一个 net 有多个驱动源）
            rf_fill_line <= 16'd0;
            rf_start     <= 1'b0;
            rf_pending   <= 1'b0;
            frame_sel    <= 1'b0;
        end else begin
            rf_start <= 1'b0;
            if (frame_tog_p) begin
                // 帧起始：补第 0 行（期间是场消隐，时间充裕）
                rf_fill_line <= 16'd0;
                rf_pending   <= 1'b1;
                frame_sel    <= rd_sel_v;      // 整帧的读基准在这一刻定下来
            end else if (line_tog_p) begin
                // 行起始：补下一行；行 479 之后不再补，等下一帧的 frame_tog
                if (rf_fill_line + 16'd1 < V_ACTIVE) begin
                    rf_fill_line <= rf_fill_line + 16'd1;
                    rf_pending   <= 1'b1;
                end
            end else if (rf_accept) begin
                // 取行请求已被读 FSM 受理，清除挂起标志。
                // 清除必须放在本块里（rf_pending 只能有一个驱动源），
                // 且排在触发之后：同一拍又来了新触发就保持挂起。
                rf_pending <= 1'b0;
            end
        end
    end

    // ---- 读侧优先仲裁（修正死锁）----
    // 绝不能像上一版那样写成 !App_rd_en && ... ：写侧的可用性若依赖读侧自己的
    // 请求信号，就会互相等待（读侧不发请求 -> 写侧一直可用 -> 读侧永远不发请求）。
    // 正确做法：读侧在取行的整个期间（RF_REQ/RF_WAIT）独占总线；
    // 写侧只在读侧完全空闲（rf_state == RF_IDLE）时启动。
    //
    // 【为什么必须这样 —— 原文依据】官方参考文档 3.4 节（设计参考例程文档.md 第 236 行）：
    //   "一次读/写事务在完成握手后需在读/写事务长度完成后结束；或者发起一次新的请求，
    //    会将上一次事务终止并清空 FIFO。……板卡 SDRAM 读写互斥，故读事务和写事务突发
    //    同时只会进行一个，且写事务优先于读事务。"
    // 据此推出两条硬约束，本模块按此设计：
    //   ① 只要读事务还有"已发出但未返回"的字，就绝不能发写请求 ——
    //      否则这次写会把读事务终止并清空 FIFO，行内从丢弃处开始整体错位（撕裂）。
    //      本模块用 `rf_state == RF_IDLE` 代表"没有在途读数据"（只有收齐整行才会回到
    //      RF_IDLE），写侧在此期间完全禁发。
    //   ② 写事务发出后，读侧必须静默若干拍再发新请求，否则写数据可能整拍丢失（坏点）。
    //      见下面的 wr_quiet 静默窗。
    // 另外：厂商 frame_fifo_read/frame_fifo_write 都是"连续发 BURST_SIZE 拍请求 -> 拉低
    // App_*_en 至少 1 拍 -> 继续"，BURST_SIZE=128/256（frame_read_write 传 256）。
    // 所以连续同向请求之间插 1 拍空隙是安全的（不会丢在途数据），本模块照抄该节奏。

    // ---- 写后静默窗：App_wr_en 之后 4 拍内读侧不发任何请求 ----
    reg [2:0] wr_quiet;
    always @(posedge mem_clk or posedge mem_reset) begin
        if (mem_reset) wr_quiet <= 3'd0;
        else if (App_wr_en) begin
            if (wr_quiet < 3'd4) wr_quiet <= 3'd4;      // 挂着就续满，保证每次写后都够 4 拍
        end else if (wr_quiet != 3'd0)
            wr_quiet <= wr_quiet - 3'd1;
    end
    wire bus_quiet = (wr_quiet != 3'd0);

    // 写突发期间（以及写后静默窗内）读侧一律不许发请求。
    // 依据：板级实测 —— 连续突发写能写进 SDRAM（burst.bit 出现红色），
    // 但被并发读请求打断后只剩部分线条；厂商 frame_fifo_read/write 也是读写互斥、
    // 从不重叠。所以这里让读侧在写突发期间完全让路。
    wire rd_block = (wf_state == WF_BURST) || (wf_state == WF_GAP) || bus_quiet;
    wire rf_accept = rf_pending && (rf_state == RF_IDLE) &&
                     Sdr_init_done && !rd_block && !Sdr_busy;

    // ---- 自检模式状态（SELFTEST=0 时会被剪掉）----
    reg [19:0] st_cnt;                      // 已灌入 BUF0 的字数
    reg [9:0]  st_x, st_y;                  // 渐变坐标
    reg        st_active;                   // 正在灌图
    // 自检要写多少字：正常一帧 FRAME_WORDS；ST_DUAL 时连 BUF1 一起写，共两帧
    wire [19:0] st_limit = ST_DUAL ? (FRAME_WORDS + FRAME_WORDS) : FRAME_WORDS;

    always @(posedge mem_clk or posedge mem_reset) begin
        if (mem_reset) begin
            rf_state    <= RF_IDLE;
            rf_active_line <= 16'd0;
            rf_req_cnt  <= 11'd0;
            rf_recv_cnt <= 11'd0;
            rf_base     <= BUF0_ADDR;
            tr_seen<=0;tr_active<=0;tr_target<=0;tr_effect<=0;tr_next_effect<=0;tr_step<=0;
            rf_newbase<=BUF0_ADDR;rf_dual<=0;rf_second<=0;rf_line_addr<=0;rf_second_gap<=0;
            App_rd_en   <= 1'b0;
            App_rd_addr <= 21'd0;
            rf_burst_cnt<= 11'd0;
            rf_wait_cnt <= 16'd0;
            diag_fetch  <= 1'b0;
            diag_line   <= 1'b0;
            diag_to_cnt <= 4'd0;
        end else begin
            case (rf_state)
                RF_IDLE: begin
                    App_rd_en    <= 1'b0;
                    rf_burst_cnt <= 11'd0;
                    rf_wait_cnt  <= 16'd0;
                    if (rf_accept) begin
                        rf_active_line <= rf_fill_line;
                        // 注意 !rd_block：写突发期间不发请求，rf_pending 保持挂起等它结束。
                        // rf_pending 的清零在触发那个 always 块里做（避免多驱动）。
                        // 【APUG011 §7 注意3】"每次读写操作前，请判断 Sdr_busy 是否忙" ——
                        // 这里是"操作**前**"的判断（开始取这一行之前），
                        // 一旦开始就绝不再因为 Sdr_busy 中断（中断 = 事务被结束/清空 = 丢字）。
                        // 【修订(b)】行首锁存读基准：一行之内绝不变 → 换图不会撕到行中间
                        // 【关键修正】读基准只在"取第 0 行"时更新，其余行沿用上一拍的值，
                        // 这样一帧之内恒定（不会帧中途换图 -> 撕裂），
                        // 而且**不依赖 frame_tog 边沿是否可靠** —— 之前用边沿锁存 frame_sel，
                        // 一旦那个边沿不来，整帧就永远锁死在 BUF0，表现为"按 K2 画面不变"。
                        rf_second<=0;
                        if(rf_fill_line==0)begin
                            if(!TRANSITIONS||SELFTEST)begin
                                rf_base<=rd_sel_v?BUF1_ADDR:BUF0_ADDR;rf_dual<=0;
                            end else if(!tr_seen)begin
                                rf_base<=rd_sel_v?BUF1_ADDR:BUF0_ADDR;rf_dual<=0;
                                if(display_valid_sync[1])tr_seen<=1;
                            end else if(tr_active)begin
                                if(tr_step==32)begin
                                    rf_base<=tr_target?BUF1_ADDR:BUF0_ADDR;
                                    tr_active<=0;rf_dual<=0;
                                end else begin tr_step<=tr_step+1'b1;rf_dual<=1;end
                            end else if(rd_sel_v!=(rf_base==BUF1_ADDR))begin
                                if(chosen_effect==0)begin
                                    rf_base<=rd_sel_v?BUF1_ADDR:BUF0_ADDR;rf_dual<=0;tr_active<=0;
                                end else begin
                                    tr_active<=1;tr_target<=rd_sel_v;tr_step<=0;
                                    tr_effect<=chosen_effect==1;tr_next_effect<=~tr_next_effect;
                                    rf_newbase<=rd_sel_v?BUF1_ADDR:BUF0_ADDR;rf_dual<=1;
                                end
                            end else rf_dual<=0;
                        end
                        rf_req_cnt  <= 11'd0;
                        rf_recv_cnt <= 11'd0;
                        rf_state    <= TRANSITIONS?RF_SETUP:RF_REQ;
                        diag_fetch  <= 1'b1;      // 诊断：读通路至少启动过一次
                    end
                end

                RF_SETUP: begin
                    App_rd_en<=0;
                    rf_line_addr<=(rf_second?rf_newbase:rf_base)+rf_active_line*H_ACTIVE;
                    rf_state<=RF_REQ;
                end
                RF_SECOND: begin
                    App_rd_en<=0;
                    if(rf_second_gap<16)rf_second_gap<=rf_second_gap+1'b1;
                    else if(!Sdr_busy&&!rd_block)begin
                        rf_second<=1;rf_req_cnt<=0;rf_recv_cnt<=0;rf_burst_cnt<=0;rf_wait_cnt<=0;
                        rf_state<=RF_SETUP;
                    end
                end
                RF_REQ: begin
                    // 本行 640 个字一次连续读完：中途绝不插入空隙（见 RD_BURST_MAX 处说明）。
                    // rd_block 理论上此时不会变高（写侧只在 rf_state==RF_IDLE 时才启动），
                    // 这里保留只是防御。
                    if (rd_block) begin
                        App_rd_en <= 1'b0;
                    end else if (rf_burst_cnt == RD_BURST_MAX - 11'd1) begin
                        App_rd_en    <= 1'b0;
                        rf_burst_cnt <= 11'd0;
                    end else begin
                        App_rd_en   <= 1'b1;
                        App_rd_addr <= TRANSITIONS ? (rf_line_addr+rf_req_cnt) : (rf_base + rf_active_line * H_ACTIVE + rf_req_cnt);
                        rf_burst_cnt<= rf_burst_cnt + 11'd1;
                        if (rf_req_cnt == H_ACTIVE - 1) rf_state <= RF_WAIT;
                        else rf_req_cnt <= rf_req_cnt + 11'd1;
                    end
                end

                RF_WAIT: begin
                    App_rd_en <= 1'b0;
                    // 等本行 640 个字全部收到（rf_recv_cnt 由 Sdr_rd_en 推进）
                    if (rf_recv_cnt >= H_ACTIVE) begin
                        if(TRANSITIONS&&rf_dual&&!rf_second)begin rf_state<=RF_SECOND;rf_second_gap<=0;end
                        else rf_state <= RF_IDLE;
                    end else if (rf_wait_cnt > RD_WAIT_TIMEOUT) begin
                        // 兜底：若事务真被写请求打断，尾部若干字永远不会回来。
                        // 此时按"丢失的一定是最后发出的那批（SDRAM 顺序返回）"从
                        // rf_recv_cnt 处重发缺失的尾部，数据仍落在正确位置，不会错位。
                        // 【诊断】这一刻就说明"这一行没能在一次事务里凑齐" —— 计数上数码管。
                        rf_wait_cnt <= 16'd0;
                        rf_req_cnt  <= rf_recv_cnt;
                        rf_burst_cnt<= 11'd0;
                        rf_state    <= RF_REQ;
                        if (diag_to_cnt != 4'hf) diag_to_cnt <= diag_to_cnt + 4'd1;
                    end else begin
                        rf_wait_cnt <= rf_wait_cnt + 16'd1;
                    end
                end

                default: rf_state <= RF_IDLE;
            endcase

            // 收到的数据按序写入行缓存（SDRAM 按请求顺序返回）
            // 诊断模式 ROTSWEEP 下按 rot_s 做行内环移（rot_s=0 时就是原样）
            if (Sdr_rd_en && (rf_state != RF_IDLE) && (rf_recv_cnt < H_ACTIVE)) begin
                if(TRANSITIONS&&rf_second)
                    line_mem_new[(rf_active_line[0] ? H_ACTIVE : 0) + rot_idx] <= Sdr_rd_dout;
                else line_mem[(rf_active_line[0] ? H_ACTIVE : 0) + rot_idx] <= Sdr_rd_dout;
                rf_recv_cnt <= rf_recv_cnt + 11'd1;
                rf_wait_cnt <= 16'd0;
                if (rf_recv_cnt == H_ACTIVE - 1) diag_line <= 1'b1;   // 诊断：收满过一整行
            end
        end
    end

    // =====================================================================
    // 3.5 写侧突发（mem_clk）：WF_IDLE -> WF_BURST -> WF_GAP
    //
    // ── 对齐推导（本轮修掉的第二个真 bug：整帧写数据错位 1 字）─────────────
    //   afifo_32_256 是非 FWFT：rd_en 在 T 拍为高 => dout 在 T+1 拍才是那个字。
    //   fifo_re / App_wr_din / App_wr_addr / App_wr_en 全是 mem_clk 寄存器，于是
    //   "写"发生在引脚上时，用的是**上一拍寄存进去的值**。设突发的第 0 拍为 cycle 0：
    //     弹 FIFO 发生在 cycle 0..wf_len-1  =>  dout = word0..word(wf_len-1) 在 cycle 1..wf_len
    //     写脉冲出现在 cycle 2..wf_len+1（App_wr_en <= (wf_rc != 0)）
    //     cycle N 写下去的数据 = dout(N-1) = word(N-2)，地址 = wr_base + wr_word_cnt(N-1)
    //     wr_word_cnt 在每个 rc!=0 的拍末自增 => wr_word_cnt(N) = N-1  =>  地址偏移 = N-2
    //   => 数据与地址**逐字对齐**（word0->base+0 ... word(wf_len-1)->base+wf_len-1）✓
    //   【关键前提】第 0 次弹 FIFO 必须在"进入 WF_BURST 之前那一拍"就发出（即 WF_IDLE 里
    //   fifo_re <= 1）。旧版在 WF_BURST 里才发第一次弹，整体晚一拍：
    //   SDRAM[base+0] 是脏值、SDRAM[base+k] = word(k-1)、最后一个字丢失
    //   （= 交接笔记里"整帧后移一个字"，本轮实测复现，务必别再改回去）。
    // =====================================================================
    localparam [2:0] WF_IDLE = 3'd0, WF_BURST = 3'd1, WF_GAP = 3'd2;

    reg [2:0]  wf_state;
    reg [8:0]  wf_rc;                       // 突发内拍计数：0..wf_len（到 wf_len 即收工）
    reg [8:0]  wf_len;                      // 本次突发的字数（启动那一刻锁存）
    reg [2:0]  wf_gap;                      // WF_GAP 内的断开拍计数
    reg [19:0] wr_word_cnt;                 // 本帧已写入 SDRAM 的字数
    reg        wr_busy_mem;                 // 本帧写任务进行中
    reg [20:0] wr_base;                     // 本帧目标缓冲区基址
    reg        wr_fin_done;                 // 本帧提交脉冲已发过（防重复翻转）

    // ---- 写地址生成（支持垂直翻转）----
    //   不翻转：偏移 = 0,1,2,...（顺序）
    //   翻转  ：偏移从 (V_ACTIVE-1)*H_ACTIVE 起，行内 +1；
    //           行尾为 (r*W + W-1)，下一行首是 (r-1)*W，
    //           所以行尾要跳 -( (r*W+W-1) - (r-1)*W ) = -(2W-1)
    //           —— 这正是厂商 frame_fifo_write.v 里的 VFLIP_LINE_JUMP = W*2-1。
    //           （只减 W 是错的：那会少减 W-1，整帧地址全部漂移。）
    //           → 文件第 r 行落到显示第 (V_ACTIVE-1-r) 行，列序不变（纯垂直翻转）
    localparam [9:0]  WR_COL_LAST = H_ACTIVE - 1;
    localparam [20:0] WR_ROW_STEP = (H_ACTIVE * 2) - 1;
    localparam [20:0] VFLIP_OFF0  = (V_ACTIVE - 1) * H_ACTIVE;
    reg [20:0] wr_addr_off;
    reg [9:0]  wr_col;

    // ---- 自检图案（SELFTEST 用）：16x16 个色块，色块颜色直接编码它该在的位置 ----
    //   R = block_x * 16、G = block_y * 16、B = 棋盘格
    //   任何错位/丢字/整块搬移在照片上都一眼可见（原来的渐变图不好判读）
    reg [3:0]  st_bx, st_by;                // 色块坐标 0..15
    reg [5:0]  st_px_cnt;                   // 块内列计数 0..39
    reg [4:0]  st_ln_cnt;                   // 块内行计数 0..29
    wire [7:0] st_pat_r = {st_bx, 4'h0};
    wire [7:0] st_pat_g = {st_by, 4'h0};
    wire [7:0] st_pat_b = ((st_bx[0] ^ st_by[0]) != 1'b0) ? 8'h80 : 8'h00;

    // ---- 【偏移定标】源字序号计数器（RULER 用）----
    //   fifo_re 在第 t 拍弹出第 k 个字，该字在第 t+1 拍出现在 fifo_dout 上。
    //   src_idx_c 在 t 拍 +1（t+1 拍可见 = k+1），src_idx_d 打一拍 = k，
    //   正好与"当前 dout 上是第几个源字"对齐。
    reg [19:0] src_idx_c, src_idx_d;
    always @(posedge mem_clk or posedge mem_reset) begin
        if (mem_reset) begin
            src_idx_c <= 20'd0;
            src_idx_d <= 20'd0;
        end else begin
            src_idx_d <= src_idx_c;
            if (fifo_re) src_idx_c <= src_idx_c + 20'd1;
        end
    end
    wire [23:0] wr_src_pix = fifo_dout[31:8];
    wire [23:0] wr_rul_pix = (src_idx_d[5:0] != 6'd0) ? wr_src_pix
                            : (src_idx_d[19:6] == 14'd0) ? 24'h00FF00   // 源图第 0 列：纯绿
                                                         : 24'hFF0000;  // 每 64 个源字：纯红（1 像素）
    wire [31:0] wr_dat_fin = SELFTEST
                           ? (ST_DUAL ? (st_cnt < FRAME_WORDS ? {24'hFF0000, 8'h00}
                                                             : {24'h00FF00, 8'h00})
                                      : (ST_SOLID ? {24'hFF0000, 8'h00}
                                                  : {st_pat_r, st_pat_g, st_pat_b, 8'h00}))
                           : (RULER ? {wr_rul_pix, 8'h00} : fifo_dout);

    // ---- 【横向偏移】帧首补黑字 ----
    //   ⚠ 下面的"补 170 个字"是第四轮的结论；**条数现在每帧实测**（见紧接着的一段），
    //     `WR_LEAD` 已降级为"源端没报数时的兜底值"。这段历史留档，别按它改代码。
    //   板级事实（第四轮量出来的，见交接文档 §0.0）：
    //     · 源端每帧实际只送出 307029 个字，比一整帧少 **170** 个；
    //     · 于是写指针停在"显示第 0 行、第 469 列"，图像最上一行最右 170 列从没被写过
    //       —— 这正是用户看到的"右边边界小锯齿"（残留数据与图像内容的分界）；
    //     · 同时所有内容都整体**左移了 170 个像素**（接缝落在源列 640-170 = 470）。
    //   修法（**完全在写侧，不碰显示、不碰 SD 数据流**）：
    //     每帧开头先连续写 WR_LEAD 个"纯黑"字，把源端缺的那 170 个位置占掉。
    //     这样后面源端的 307029 个字全部落在**正确地址**上：
    //       内容不再左移、接缝消失、右边那 170 列也变成正常的图像内容（不再是残留）。
    //     代价：图像最下面一行的左边 170 列变成黑色（就一小条，那是本来就没送来的数据）。
    //   注意：黑字是**本模块自己产生**的，不进 FIFO、不改 SD 侧任何时序
    //        —— 上一版（wrfix11）把补偿塞进 SD 数据流才导致整屏撕裂，不能再那么干。
    reg  [9:0] wf_lead_left;                 // 帧首还要补多少个黑字
    reg        wf_lead_mode;                 // 当前这次突发是"补黑"而不是搬 FIFO
    // =====================================================================
    // 【横向偏移根治】补黑条数改为"每帧实测"，不再写死一个常数
    //
    //   事实（板级量化，见交接笔记 §0.0）：帧首那段内容会**时有时无地少掉**——
    //   少掉时整幅图左移 170 像素（=510 字节 = 一个扇区量级），不少的时候位置就是对的。
    //   所以固定 LEAD_PX=172 只在"这一帧确实少了"时正确：一旦某一帧没少，
    //   固定的 172 反而把整幅图右推 172 像素。用户看到的"图还是那张、但横向偏了"
    //   就是这个：同一张图，第一帧少→补对了，后面几帧没少→被多推了 172。
    //
    //   现在的做法：
    //     ① 主项 = 源端实测（bmp_read 用"第一个数据扇区实收字节数"算出的缺字数）；
    //     ② 兜底项 = 上一帧**实际少写进 SDRAM 的字数**（万一丢字发生在写 FIFO 里）；
    //     ③ 两者相加后取最近的 4 的倍数（APUG011 §2.4：地址跳跃必须是 4 的倍数，
    //        否则 SDRAM IP 的 4 字内部累加与主机地址对不上 → 屏幕出"栅格"）。
    //     ④ 帧开始后**先等源端报数再发第一批**（源端约 200us 后就有数；FIFO 里此时
    //        最多约 200 字 < 256 深，等得起）。万一源端一直不报，就用 WR_LEAD 参数兜底。
    // =====================================================================
    reg  [1:0]  lead_vld_s;                  // valid 的 2 级同步
    reg  [9:0]  lead_w1_s, lead_w2_s;        // 10 位实测值的 2 级同步（跨时钟域，值慢变）
    reg  [9:0]  lead_words_s;                // 同步过来的实测值（源端未报数时 = WR_LEAD）
    reg  [9:0]  fifo_def_prev;               // 上一帧少写进 SDRAM 的字数（兜底项；只由写 FSM 块赋值）
    reg         lead_pending;                // 本帧的补黑条数还没定下来
    reg  [17:0] lead_wait;                   // 等源端报数的兜底计时（mem_clk 拍）
    reg  [3:0]  lead_tries;                  // 诊断：收到过几次源端报数
    // 【重要】wf_lead_left / wf_lead_mode / fifo_def_prev 都只能由写 FSM 那一个 always 块驱动
    //   （TD 报 HDL-8007 多驱动），所以这里只抬一个"定下来了"的单拍脉冲 + 值。
    reg         lead_latch_pulse;
    reg  [9:0]  lead_latch_val;
    // 【同步后的 valid"新到"脉冲】链是 {s[0], 输入}，所以"刚到"= s[0] 高而 s[1] 还低
    //   （用 s[1]&~s[0] 是错的：那时 s[0] 已经高了一拍，永远不成立 —— 踩过）
    wire        lead_new_pulse = lead_vld_s[0] & ~lead_vld_s[1];
    localparam [17:0] LEAD_WAIT_MAX = 18'd250_000;   // 2ms @125MHz
    wire [11:0] lead_sum = {2'b0, lead_words_s} +
                           (LEAD_USE_MEAS ? 12'd0 : {2'b0, fifo_def_prev});
    // 取最近的 4 的倍数；>1023 的极端值截到 1023（正常只会是 0 或 ~172）
    wire [11:0] lead_rnd = (lead_sum + 12'd2) & 12'b0111_1111_1100;
    wire [9:0]  lead_q   = (lead_rnd > 12'd1023) ? 10'd1023 : lead_rnd[9:0];
    // 刚收到报数那一拍：直接用同步后的输入值算（lead_words_s 还没更新）
    wire [11:0] lead_sum_in = {2'b0, lead_w2_s} +
                              (LEAD_USE_MEAS ? 12'd0 : {2'b0, fifo_def_prev});
    wire [11:0] lead_rnd_in = (lead_sum_in + 12'd2) & 12'b0111_1111_1100;
    wire [9:0]  lead_q_in   = (lead_rnd_in > 12'd1023) ? 10'd1023 : lead_rnd_in[9:0];
    wire        lead_decided = ~lead_pending;

    always @(posedge mem_clk or posedge mem_reset) begin
        if (mem_reset) begin
            lead_vld_s       <= 2'b00;
            lead_w1_s        <= 10'd0;
            lead_w2_s        <= 10'd0;
            lead_words_s     <= WR_LEAD;     // 兜底：源端从没报过数时按参数值补（默认 172）
            lead_pending     <= 1'b1;
            lead_wait        <= 18'd0;
            lead_tries       <= 4'd0;
            lead_latch_pulse <= 1'b0;
            lead_latch_val   <= 10'd0;
        end else begin
            lead_latch_pulse <= 1'b0;
            lead_vld_s <= {lead_vld_s[0], wr_lead_valid};
            lead_w1_s  <= wr_lead_words;
            lead_w2_s  <= lead_w1_s;
            if (lead_new_pulse) begin
                lead_words_s <= lead_w2_s;       // 同步后的稳定值
                if (lead_tries != 4'hf) lead_tries <= lead_tries + 4'd1;
            end
            if (wr_start_p) begin
                if (LEAD_USE_MEAS) begin
                    // 新的一帧：先不定补黑条数，等源端实测值
                    lead_pending <= 1'b1;
                    lead_wait    <= 18'd0;
                end else begin
                    // 【本轮默认】固定补黑：帧一开始就用 WR_LEAD，不等源端、时序与 wrfix13 一致
                    lead_pending     <= 1'b0;
                    lead_latch_pulse <= 1'b1;
                    lead_latch_val   <= WR_LEAD;
                    lead_wait        <= 18'd0;
                end
            end else if (lead_pending) begin
                if (lead_wait != 18'h3ffff) lead_wait <= lead_wait + 18'd1;
                // 定下来的条件：源端报数到了 / 等太久了 / FIFO 快满不能再等
                if (lead_new_pulse || (lead_wait > LEAD_WAIT_MAX) || (fifo_rd_used > 9'd200)) begin
                    lead_pending     <= 1'b0;
                    lead_latch_pulse <= 1'b1;
                    // 【本轮按交接笔记《颜色与位置》恢复】固定补黑 = wrfix13 已验证的行为。
                    //   实测值只做诊断（LEAD_USE_MEAS=0 时不参与），因为板上实测会给出 0
                    //   （那次扇区读是"内容错位、字节数不少"，字节计数根本看不出来）。
                    lead_latch_val   <= LEAD_USE_MEAS ? (lead_new_pulse ? lead_q_in : lead_q)
                                                     : WR_LEAD;
                end
            end
        end
    end
    wire       wr_lead_pending = (wf_lead_left != 10'd0);
    // 【必须 4 的倍数 —— 板级踩过的坑】APUG011 手册 §2.4：
    //   "数据以 4 个为单位传输，每 4 个只用首地址、内部累加；地址跳跃必须是 4 的倍数"。
    //   补黑长度若 ≡ 2 (mod 4)（例如 170），后面每个写突发的起始地址就都错开 2 个地址，
    //   IP 的内部 4 字累加与主机地址对不上 => 每批数据各自错位几个字 =>
    //   屏幕上出现"竖向每列不对齐 / 像栅格图"。现在的取整在 lead_rnd 里做（取最近 4 的倍数）。

    // Snapshot the conservative FIFO count before burst arbitration. During
    // an active burst its delayed count is ignored; bus_quiet allows it to
    // settle before the next burst can start.
    reg [8:0] fifo_avail_q;
    always @(posedge mem_clk or posedge mem_reset) begin
        if (mem_reset) fifo_avail_q <= 0;
        else fifo_avail_q <= fifo_rd_used;
    end
    // ---- 突发启动条件 ----
    reg [19:0] wr_remain;
    reg [8:0] wr_avail;
    always @(posedge mem_clk or posedge mem_reset) begin
        if (mem_reset) begin wr_remain <= FRAME_WORDS; wr_avail <= 0; end
        else begin
            wr_remain <= FRAME_WORDS - wr_word_cnt;
            wr_avail <= (wr_remain > {11'd0, fifo_avail_q}) ? fifo_avail_q : wr_remain[8:0];
        end
    end
    wire [8:0]  wr_burst_len = ((wr_avail > WR_BURST_LEN) ? WR_BURST_LEN : wr_avail) & 9'h1fc;

    // 正式通路：FIFO 里攒够一整批（WR_BURST_LEN，默认 128）就连续写完它；
    //          源端已送完时，把剩下的（可能不足一批）也发出去 —— 收尾。
    // 自检通路：数据由计数器自己产生，只要读侧空闲就能写。
    // 【写侧不判断 Sdr_busy】手册 §7 注意3 虽要求"读写前判断 Sdr_busy"，
    // 但板级实测：写侧加上这个条件后写突发几乎等不到机会，整帧在 1s 超时内写不完
    // -> 提交不发生 -> 永远黑屏。写侧只靠"读侧完全空闲 + 连续突发"，
    // 读侧保留 Sdr_busy 判断（读侧加了它才收敛，见 RF_REQ）。
    // 帧首补黑（wr_lead_pending）不等 FIFO，帧一开始就能发 —— 但它同样只在读侧空闲时发。
    // 【横向偏移根治】lead_decided：补黑条数还没定下来之前，一帧里一个字都不写（
    //   连补黑都不发），这样"补多少"才可能按实测值来。
    wire wr_go = SELFTEST
               ? (st_active && (rf_state == RF_IDLE) && !bus_quiet)
               : (wr_busy_mem && !bus_quiet && (rf_state == RF_IDLE) && lead_decided &&
                  (wr_lead_pending ||
                   (wr_avail >= WR_BURST_LEN) || (wr_src_done && (wr_avail >= 9'd4))));

    // 一帧结束（提交）：源端送完（或长时间无新字）+ 没有在途突发 +
    //   （FIFO 已排空 或 已经写满一整帧）。
    // 用"源端+排空"而不是"数到 307199"来判定，是为了让任何异常（丢字、SD 提前结束）
    // 都不会把提交彻底卡死 —— 宁可显示一张不完整的图，也绝不黑屏；
    // 后半条"已写满一整帧"是防"源端送来的字比 FRAME_WORDS 还多"（那样 FIFO 永远排不空）。
    wire wr_frame_end = !SELFTEST && wr_busy_mem && !wr_fin_done &&
                        src_all_sent && !overflow_sync[1] && fifo_empty &&
                        (wr_word_cnt == FRAME_WORDS) && !bus_quiet &&
                        (wf_state == WF_IDLE);

    always @(posedge mem_clk or posedge mem_reset) begin
        if (mem_reset) begin
            wf_state       <= WF_IDLE;
            wf_rc          <= 9'd0;
            wf_len         <= 9'd0;
            wf_gap         <= 3'd0;
            App_wr_en      <= 1'b0;
            App_wr_addr    <= 21'd0;
            App_wr_din     <= 32'd0;
            fifo_re        <= 1'b0;
            wr_word_cnt    <= 20'd0;
            wr_busy_mem    <= 1'b0;
            wr_base        <= BUF0_ADDR;
            wr_fin_done    <= 1'b0;
            wr_addr_off    <= 21'd0;
            wr_col         <= 10'd0;
            write_finish_toggle <= 1'b0;
            st_cnt         <= 20'd0;
            st_x           <= 10'd0;
            st_y           <= 10'd0;
            st_bx          <= 4'd0;
            st_by          <= 4'd0;
            st_px_cnt      <= 6'd0;
            st_ln_cnt      <= 5'd0;
            st_active      <= 1'b0;
            wf_lead_left   <= 10'd0;
            wf_lead_mode   <= 1'b0;
            fifo_def_prev  <= 10'd0;
        end else if (wr_req_mem[2]) begin
            // A new request cancels the previous write transaction before ack.
            wf_state <= WF_IDLE;
            App_wr_en <= 1'b0;
            fifo_re <= 1'b0;
            wr_busy_mem <= 1'b0;
            wr_fin_done <= 1'b0;
            wf_lead_left <= 10'd0;
            wf_lead_mode <= 1'b0;
        end else begin
            App_wr_en <= 1'b0;
            fifo_re   <= 1'b0;

            // 【横向偏移根治】补黑条数定下来了（来自 lead 逻辑的单拍脉冲）：
            //   本帧先写这么多纯黑字，后面的源端数据就落回正确地址。
            if (lead_latch_pulse) begin
                wf_lead_left <= SELFTEST ? 10'd0 : lead_latch_val;
                wf_lead_mode <= 1'b0;
            end

            // 自检：SDRAM 初始化完成后开始向 BUF0 灌图
            // 【勿删】这里原来漏了"把 st_active 置 1"，导致所有自检 bit 里一个写都没发出，
            // 屏幕显示的一直是 SDRAM 上电内容，把结论带偏过。
            if (SELFTEST && !st_active && Sdr_init_done && (st_cnt < st_limit))
                st_active <= 1'b1;

            // 帧起始：锁存目标缓冲区（电平已由 3 拍链稳定）+ 写地址起点
            if (wr_start_p) begin
                wr_busy_mem <= 1'b1;
                wr_word_cnt <= 20'd0;
                wr_base     <= wr_sel_v ? BUF1_ADDR : BUF0_ADDR;
                wr_fin_done <= 1'b0;
                wr_addr_off <= wr_flip_sync[2] ? VFLIP_OFF0 : 21'd0;
                wr_col      <= 10'd0;
                // 【横向偏移根治】帧首补黑条数由 lead 逻辑（等源端实测）决定，这里先清零
                wf_lead_left<= 10'd0;
                wf_lead_mode<= 1'b0;
            end

            case (wf_state)
                WF_IDLE: begin
                    if (wr_go) begin
                        if (wr_lead_pending) begin
                            // 【横向偏移】先补黑：不发 FIFO 弹读请求，数据用纯黑
                            wf_len       <= (wf_lead_left > {1'b0, WR_BURST_LEN})
                                            ? WR_BURST_LEN : wf_lead_left[8:0];
                            wf_lead_mode <= 1'b1;
                            fifo_re      <= 1'b0;
                        end else begin
                            wf_len       <= SELFTEST ? WR_BURST_LEN : wr_burst_len;
                            wf_lead_mode <= 1'b0;
                            // 【对齐关键，勿改】第一次弹 FIFO 必须在进入 WF_BURST 之前发出
                            fifo_re      <= SELFTEST ? 1'b0 : 1'b1;
                        end
                        wf_rc    <= 9'd0;
                        wf_gap   <= 3'd0;
                        wf_state <= WF_BURST;
                    end else if (wr_frame_end) begin
                        wr_busy_mem         <= 1'b0;
                        wr_fin_done         <= 1'b1;
                        write_finish_toggle <= ~write_finish_toggle;
                        // 【横向偏移根治·兜底项】这一帧实际少写进 SDRAM 的字数。
                        //   正常情况下源端送满、一个字都不丢 => wr_remain = 0。
                        //   只有"写 FIFO 被写满丢弃"时才会不为 0，那同样表现为整帧左移，
                        //   于是把它当作下一帧的补充黑字数（小缺口才认，大缺口=异常，归零）。
                        if (src_stalled)              fifo_def_prev <= 10'd0;
                        else if (wr_remain < 20'd1024) fifo_def_prev <= wr_remain[9:0];
                        else                          fifo_def_prev <= 10'd0;
                    end
                end

                // -----------------------------------------------------------------
                // WF_BURST：连续 wf_len 拍不间断地写（App_wr_en 连续为高）
                //   cycle 0      : fifo_re=1；App_wr_en=0（lead-in，只弹不写）
                //   cycle 1..wf_len : fifo_re = (wf_rc < wf_len-1)，App_wr_en=1
                //   cycle wf_len+1  : 已是 WF_GAP，但这一拍 App_wr_en 仍为高 =>
                //                     连写拍数正好 = wf_len，且与上面推导一致
                //   【横向偏移】wf_lead_mode 时数据固定纯黑、不弹 FIFO、不动 wr_word_cnt。
                // -----------------------------------------------------------------
                WF_BURST: begin
                    App_wr_en   <= (wf_rc != 9'd0);
                    fifo_re     <= (wf_lead_mode || SELFTEST) ? 1'b0 : (wf_rc < (wf_len - 9'd1));
                    App_wr_addr <= SELFTEST ? (BUF0_ADDR + {1'b0, st_cnt})
                                            : (wr_base + wr_addr_off);
                    App_wr_din  <= wf_lead_mode ? 32'h0000_0000 : wr_dat_fin;

                    // 每个"已写出"的拍推进地址/数据计数（rc=0 是 lead-in，不推进）
                    // 补黑的字与正常字走**完全相同**的地址推进（它们占的就是帧首那 170 个位置）
                    if (wf_rc != 9'd0) begin
                        // ---- 写地址推进（垂直翻转时行内 +1、行尾 -H_ACTIVE）----
                        if (wr_flip_latched && (wr_col == WR_COL_LAST)) begin
                            wr_col      <= 10'd0;
                            wr_addr_off <= wr_addr_off - WR_ROW_STEP;
                        end else begin
                            if (wr_flip_latched) wr_col <= wr_col + 10'd1;
                            wr_addr_off <= wr_addr_off + 21'd1;
                        end
                        // ---- 自检图案坐标推进 ----
                        if (SELFTEST) begin
                            st_cnt <= st_cnt + 20'd1;
                            // 每 40 像素换一个色块列
                            if (st_px_cnt == 6'd39) begin
                                st_px_cnt <= 6'd0;
                                st_bx     <= st_bx + 4'd1;
                            end else begin
                                st_px_cnt <= st_px_cnt + 6'd1;
                            end
                            if (st_x == 10'd639) begin
                                st_x      <= 10'd0;
                                st_y      <= st_y + 10'd1;
                                st_bx     <= 4'd0;          // 行首色块列归零
                                st_px_cnt <= 6'd0;
                                // 每 30 行换一个色块行
                                if (st_ln_cnt == 5'd29) begin
                                    st_ln_cnt <= 5'd0;
                                    st_by     <= st_by + 4'd1;
                                end else begin
                                    st_ln_cnt <= st_ln_cnt + 5'd1;
                                end
                            end else begin
                                st_x <= st_x + 10'd1;
                            end
                        end else if (wr_word_cnt != FRAME_WORDS) begin
                            wr_word_cnt <= wr_word_cnt + 20'd1;
                        end
                    end

                    if (wf_rc == wf_len) begin
                        wf_gap   <= 3'd0;
                        wf_state <= WF_GAP;
                        if (SELFTEST && (st_cnt == st_limit - 20'd1)) st_active <= 1'b0;
                        if (wf_lead_mode)
                            wf_lead_left <= wf_lead_left - {1'b0, wf_len};   // 【横向偏移】这一批补完，扣掉
                    end else begin
                        wf_rc <= wf_rc + 9'd1;
                    end
                end

                WF_GAP: begin
                    // 主动拉低 App_wr_en 若干拍，明确结束本次写事务
                    App_wr_en <= 1'b0;
                    if (wf_gap == 3'd3) wf_state <= WF_IDLE;
                    else                wf_gap   <= wf_gap + 3'd1;
                end

                default: wf_state <= WF_IDLE;
            endcase
        end
    end

endmodule


// ---------------------------------------------------------------------------
// 4) 顶层（端口名与原 top 一致，pin.adc 不用改）
// ---------------------------------------------------------------------------
module top_hdmi_bmp #(
    parameter SELFTEST = 1'b0,       // 1 = 自检A：不读 SD 卡，直接显示 SDRAM 渐变图
    parameter BARS     = 1'b0,       // 1 = 自检B：完全不用 SDRAM，只显示彩条
    parameter DIAG     = 1'b0,       // 1 = 诊断D：整屏纯色报告读通路卡在哪一步
    parameter SOLID    = 1'b0,       // 1 = 自检C：向 SDRAM 写一整屏纯红（写回读判别）
    parameter BURST    = 1'b0,       // 1 = 自检E：用连续 256 拍突发写（对照孤立单拍写）
    parameter DUAL     = 1'b0,       // 1 = 自检F：BUF0 写红、BUF1 写绿，判别显示在读哪块
    parameter CNT      = 1'b0,       // 1 = 诊断G：整屏颜色报告"扫描到几张图"
    parameter BUFCHK   = 1'b0,       // 1 = 诊断H：整屏颜色报告"提交与显示缓冲区是否一致"
    parameter SEGCNT   = 1'b1,       // 1 = 诊断I：数码管额外两位显示"加载次数/提交次数"（十六进制）
    parameter        ROTSWEEP = 1'b0,       // 1 = 诊断J：环移按档位每秒 +1（16 档循环）
    parameter [9:0]  ROT_SWEEP_STEP = 10'd1, // 扫描步长（像素）：1=细扫±8，40=粗扫半行
    // 固定的行内横向环移（像素，可为负）：补偿"数据流相对光栅错开 K 个像素"
    parameter signed [10:0] ROT_PX = 11'sd0,
    // Optional legacy cyclic permutation {B,R,G}. Normal BMP assembly already
    // produces RGB, so repair41 defaults to direct RGB without this compensation.
    parameter        RGB_ROT = 1'b0,
    // 1 = 偏移定标诊断：在写侧给源图每 64 个像素打一根纯红刻度、第 0 列打绿色，
    //     用来"量"出源图第 0 列落在屏幕的哪个位置、以及写通路有没有丢字。
    //     正式构建必须为 0。
    parameter        RULER   = 1'b0,
    // 【横向偏移】帧首补黑的**兜底值**（只在源端没能报出实测值时用）。
    //   板级量出来是 170：接缝落在源列 470，640-470 = 170。正常情况这个参数用不到 ——
    //   真正的补黑条数由 bmp_read 每帧实测（见 my_sdram_frame 里的 lead 逻辑）。
    parameter [9:0]  LEAD_PX = 10'd0
)(
    input                       clk,
    input phy_rgmii_rx_clk,phy_rgmii_rx_ctl,
    input[3:0]phy_rgmii_rx_data,
    input                       rst_n,
    input                       sw1,
    input                       key1,           // 板上 KEY2 (B2)：读取/搜索下一张
    input key3,
    input                       key2,           // 板上 KEY4 (C1)：自动轮播/设置调整
    inout [15:0]                tft_data,
    output tft_cs_n,tft_rs,tft_wr_n,tft_rd_n,tft_rst_n,tft_bl,
    input nav_up,nav_down,nav_left,nav_right,nav_center,nav_set,nav_reset,

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
    // ---- 复位：POR ----
    wire sys_pll_lock, video_pll_lock, rst_all;
    reg [19:0] rst_cnt; reg rst_all_reg;
    always @(posedge clk) begin
        if (!rst_n) begin rst_cnt <= 20'd0; rst_all_reg <= 1'b1; end
        else if (!rst_all_reg) rst_all_reg <= 1'b0;
        else if (sys_pll_lock && video_pll_lock) begin
            if (rst_cnt < 20'd1_000_000) begin rst_cnt <= rst_cnt + 1'b1; rst_all_reg <= 1'b1; end
            else rst_all_reg <= 1'b0;
        end else begin rst_cnt <= 20'd0; rst_all_reg <= 1'b1; end
    end
    assign rst_all = rst_all_reg;

    // ---- 时钟 ----
    wire sd_card_clk, ext_mem_clk, ext_mem_clk_sft, video_clk, hdmi_5x_clk;
    sys_pll sys_pll_m0 (.refclk(clk), .reset(1'b0), .extlock(sys_pll_lock),
                        .clk0_out(sd_card_clk), .clk1_out(ext_mem_clk), .clk2_out(ext_mem_clk_sft));
    video_pll video_pll_m0 (.refclk(clk), .reset(1'b0), .extlock(video_pll_lock),
                            .clk0_out(video_clk), .clk1_out(hdmi_5x_clk));

    // Ethernet emergency channel: FCS/IP validated commands cross a held mailbox.
    wire[9:0]emergency_command;wire emergency_request,emergency_ack;
    wire[1:0]emergency_state,emergency_frame_state;wire[7:0]emergency_seconds;
    wire emergency_warn_blink,emergency_red_blink;
    wire clear_alarm_pixel;
    emergency_udp_rx u_emergency_rx(.rx_clk(phy_rgmii_rx_clk),.rst(rst_all),
      .rx_data(phy_rgmii_rx_data),.rx_ctl(phy_rgmii_rx_ctl),
      .acknowledge(emergency_ack),.command(emergency_command),.request(emergency_request));
    emergency_control u_emergency_control(.clk(video_clk),.rst(rst_all),
      .local_clear(clear_alarm_pixel),.source_command(emergency_command),.source_request(emergency_request),.acknowledge(emergency_ack),
      .state(emergency_state),.seconds(emergency_seconds),
      .blink_warning(emergency_warn_blink),.blink_emergency(emergency_red_blink));
    reg[1:0]emergency_pause_sd;
    always @(posedge sd_card_clk or posedge rst_all)begin
      if(rst_all)emergency_pause_sd<=0;else emergency_pause_sd<={emergency_pause_sd[0],emergency_state[1]};
    end

    // ---- SD 读图链路 ----
    wire [3:0]  state_code;
    wire        display_valid;
    wire [1:0]  write_buf_idx, disp_buf_idx;
    wire        sd_wr_req, sd_wr_ack, sd_wr_en;
    wire [31:0] sd_wr_data;
    wire        frame_wr_fin_tgl;
    wire [1:0]  display_buf_ack_w;
    wire sd_stream_ready;
    wire source_ready;wire[15:0]source_width,source_height;wire source_top_down;
    wire scaled_valid,scaled_busy,scaled_done,scaled_fault;wire[31:0]scaled_data;wire frame_source_ready;
    assign sd_stream_ready=source_ready;
    reg[2:0]scaler_req_pipe;
    always @(posedge sd_card_clk or posedge rst_all)begin
      if(rst_all)scaler_req_pipe<=0;else scaler_req_pipe<={scaler_req_pipe[1:0],sd_wr_req};
    end
    bmp_bilinear_scaler u_scaler(.clk(sd_card_clk),.rst(rst_all),.start(scaler_req_pipe[1]),
      .source_width(source_width),.source_height(source_height),.in_valid(sd_wr_en),.in_rgb(sd_wr_data[31:8]),.in_ready(source_ready),
      .out_valid(scaled_valid),.out_data(scaled_data),.out_ready(frame_source_ready),.busy(scaled_busy),.done(scaled_done),.fault(scaled_fault));
    wire [2:0] osd_tag0_w, osd_tag1_w;
    wire[23:0]osd_size0_w,osd_size1_w;
    wire osd_auto_w;
    wire [3:0]  img_total_w;                 // 诊断G：本次扫描到的图片张数
    wire [7:0]  dbg_hdr0_w, dbg_hdr1_w;      // 诊断：最近一次取头读到的头两字节
    wire [31:0] dbg_sector_w;                // 诊断：本次加载的目标扇区
    wire [9:0]  lead_words_w;                // 【横向偏移】源端实测的帧首补黑条数
    wire        lead_valid_w;                // 【横向偏移】实测值有效（每帧一次上升沿）
    wire [3:0]  sec_fix_w;                   // 【横向偏移 v2】第一个数据扇区错位重读次数
    wire        scan_done_w, sd_init_done_w; // 【诊断】扫描完成 / SD 初始化完成

    wire settings_mode,settings_toggle,settings_next,clear_alarm_sd;
    reg clear_toggle;reg[2:0]clear_sync;
    always @(posedge sd_card_clk or posedge rst_all)begin
      if(rst_all)clear_toggle<=0;else if(clear_alarm_sd)clear_toggle<=~clear_toggle;
    end
    always @(posedge video_clk or posedge rst_all)begin
      if(rst_all)clear_sync<=0;else clear_sync<={clear_sync[1:0],clear_toggle};
    end
    assign clear_alarm_pixel=clear_sync[2]^clear_sync[1];
    wire[3:0]settings_selected;
    wire[20:0]settings_config;
    wire[25:0]settings_frame;
    player_settings_control u_settings(.clk(sd_card_clk),.rst(rst_all),
        .key_next(key1),.key_adjust(key2),.key_clear(key3),
        .nav_up(nav_up),.nav_down(nav_down),.nav_left(nav_left),.nav_right(nav_right),
        .nav_center(nav_center),.nav_set(nav_set),.nav_reset(nav_reset),
        .settings_mode(settings_mode),.selected(settings_selected),.config_word(settings_config),
        .config_toggle(settings_toggle),.play_next(settings_next),.clear_alarm(clear_alarm_sd));
    player_settings_bridge u_settings_bridge(.clk(video_clk),.rst(rst_all),
        .source_packet({settings_mode,settings_selected,settings_config}),.source_toggle(settings_toggle),
        .vs(vs_r),.frame_packet(settings_frame));

    sd_card_bmp #(
        .EXTERNAL_CONTROL(1),.FLEXIBLE_BMP(1),
        .WAIT_DISPLAY_ACK    (1'b1),
        .CLK_FREQ_HZ         (100_000_000),
        .SCAN_START_SECTOR   (32'd0),
        .SCAN_MAX_SECTOR     (32'd131071),
        .SCAN_TARGET_COUNT   (4'd8),               // 卡上放了 4 张图（原来写死 2 ⇒ 只找到前两张）
        .LOAD_TIMEOUT_CYCLES (32'd1_200_000_000)     // 4 秒（原来 1 秒）
    ) sd_card_bmp_m0 (
        .clk(sd_card_clk), .rst(rst_all), .key_next(key1), .key_auto(key2),
        .source_width(source_width),.source_height(source_height),.source_top_down(source_top_down),
        .next_press_i(settings_next),.auto_enable_i(settings_config[0]),.settings_active_i(emergency_pause_sd[1]),
        .stream_ready(sd_stream_ready),
        .bmp_width(16'd640), .bmp_height(16'd480),
        .display_valid(display_valid), .state_code(state_code),
        .img_total(img_total_w),
        .osd_buffer0_size(osd_size0_w),.osd_buffer1_size(osd_size1_w),
        .osd_buffer0_image(osd_tag0_w), .osd_buffer1_image(osd_tag1_w), .osd_auto_mode(osd_auto_w),
        .dbg_hdr0(dbg_hdr0_w), .dbg_hdr1(dbg_hdr1_w), .dbg_load_sector(dbg_sector_w),
        .o_lead_words(lead_words_w), .o_lead_valid(lead_valid_w),
        .o_sec_fix_cnt(sec_fix_w),
        .o_scan_done(scan_done_w), .o_sd_init_done(sd_init_done_w),
        .write_finish_toggle(frame_wr_fin_tgl),
        .display_buf_ack(display_buf_ack_w),
        .write_buf_idx(write_buf_idx), .disp_buf_idx(disp_buf_idx),
        .write_req(sd_wr_req), .write_req_ack(sd_wr_ack),
        .write_en(sd_wr_en), .write_data(sd_wr_data),
        .SD_nCS(sd_ncs), .SD_DCLK(sd_dclk), .SD_MOSI(sd_mosi), .SD_MISO(sd_miso)
    );

    // ---- 视频时序 ----
    wire hs, vs, de, line_tog, frame_tog;
    wire [9:0] px, py;
    my_video_timing my_video_timing_m0 (
        .clk(video_clk), .rst(rst_all),
        .hs(hs), .vs(vs), .de(de), .x(px), .y(py),
        .line_tog(line_tog), .frame_tog(frame_tog)      // 【修订(a)】接到下面
    );

    // ---- SDRAM ----
    wire        Sdr_init_done, Sdr_init_ref_vld, Sdr_busy;
    wire        App_wr_en, App_rd_en;
    wire [20:0] App_wr_addr, App_rd_addr;
    wire [3:0]  App_wr_dm;
    wire [31:0] App_wr_din, Sdr_rd_dout, pix_data;
    wire        Sdr_rd_en;

    sdram U3 (
        .Clk(ext_mem_clk), .Clk_sft(ext_mem_clk_sft), .Rst(rst_all),
        .Sdr_init_done(Sdr_init_done), .Sdr_init_ref_vld(Sdr_init_ref_vld), .Sdr_busy(Sdr_busy),
        .App_wr_en(App_wr_en), .App_wr_addr(App_wr_addr), .App_wr_dm(App_wr_dm), .App_wr_din(App_wr_din),
        .App_rd_en(App_rd_en), .App_rd_addr(App_rd_addr),
        .Sdr_rd_en(Sdr_rd_en), .Sdr_rd_dout(Sdr_rd_dout)
    );

    my_sdram_frame #(
        .H_ACTIVE(640), .V_ACTIVE(480),
        .TRANSITIONS(!(SELFTEST||DIAG||BARS||CNT||BUFCHK)),
        .USE_EFFECT_CONTROL(1),.USE_SOURCE_ORIENTATION(1),
        .BUF0_ADDR(21'd0), .BUF1_ADDR(21'd307200),
        .SELFTEST(SELFTEST),
        .ST_SOLID(SOLID),
        .ST_BURST(BURST),
        .ST_DUAL (DUAL),
        .ROTSWEEP(ROTSWEEP),
        .ROT_SWEEP_STEP(ROT_SWEEP_STEP),
        .ROT_FIX (ROT_PX),
        .RULER   (RULER),
        .LEAD_USE_MEAS(1'b0), // never insert guessed pixels in the normal stream
        .WR_LEAD (LEAD_PX)
    ) my_sdram_frame_m0 (
        .mem_clk(ext_mem_clk), .rst(rst_all),.effect_i(settings_config[2:1]),.source_top_down(source_top_down),
        .Sdr_init_done(Sdr_init_done), .Sdr_busy(Sdr_busy),
        .App_wr_en(App_wr_en), .App_wr_addr(App_wr_addr), .App_wr_dm(App_wr_dm), .App_wr_din(App_wr_din),
        .App_rd_en(App_rd_en), .App_rd_addr(App_rd_addr),
        .Sdr_rd_en(Sdr_rd_en), .Sdr_rd_dout(Sdr_rd_dout),
        .wr_clk(sd_card_clk), .write_req(sd_wr_req), .write_req_ack(sd_wr_ack),
        .wr_source_ready(frame_source_ready),
        .write_en(scaled_valid&&frame_source_ready), .write_data(scaled_data), .write_buf_idx(write_buf_idx),
        .wr_lead_words(lead_words_w), .wr_lead_valid(lead_valid_w),
        .write_finish_toggle(frame_wr_fin_tgl),
        .display_buf_ack(display_buf_ack_w),
        .display_valid_i(display_valid),
        .disp_buf_idx(disp_buf_idx),                    // 【修订(b)】
        .video_clk(video_clk),
        .line_tog_i(line_tog), .frame_tog_i(frame_tog), // 【修订(a)】
        .line_idx(py), .pix_idx(px), .pix_data(pix_data),
        .diag_fetch(diag_fetch_w), .diag_line(diag_line_w), .diag_rsel(diag_rsel_w),
        .diag_to_cnt(diag_to_w), .diag_rot(diag_rot_w), .diag_lead(diag_lead_w)
    );

    // ---- 像素输出：pix_q 本身已是寄存输出（相对 line_idx/pix_idx 延迟 1 拍），
    //      所以数据只要配 de/hs/vs 打 1 拍即可。
    //      【修正】原来又多打了一级 vout_rgb（共 2 拍），而 de/hs/vs 只打 1 拍，
    //      导致像素与 DE 错开一整拍：整行右移 1 像素、行尾像素绕到下一行行首。
    reg [23:0] pix_aligned;
    always @(posedge video_clk or posedge rst_all) begin
        if (rst_all) pix_aligned <= 24'd0;
        else pix_aligned <= pix_data[31:8];
    end
    wire [23:0] vout_raw = pix_aligned;

    // =====================================================================
    //  【显示内容保持原样】—— 不要再动这里！
    //    经过板级验证的状态（wrswap 版）：颜色正确、无条纹、无横带，
    //    显示就是源图 640x480 原样送给 HDMI 核，由显示器自己做缩放/加黑边。
    //    上一版为了"居中留黑边"在这里做了列压缩映射，结果在屏幕上变成横条纹，
    //    已经全部删除。水平位置问题必须在"数据侧"（源图取数起点）解决，
    //    不允许再改显示几何。
    // =====================================================================
    // 【第三轮实测修正】通道循环补偿：
    //   板级两次独立测量（wrfix6 得 GBR、wrswap 得 RBG，两者自洽）说明管道把
    //   源图 (R,G,B) 显示成了 (G,B,R)，即在显示端需要再"正向旋转一格"才能还原：
    //   送出 {B,R,G}（= 把输出字的三个字节循环移位）后，显示端看到的就是 (R,G,B)。
    // 【颜色 —— 相位比色仪表（SEGCNT=1）】通道补偿每约 3 秒自动前进一格（mod 3）：
    //   rot1 → rot2 → rot0 → rot1 → …
    //   用法：按一次 K2 停住一张图，然后**别按键**，每 3 秒颜色会变一次；
    //   三种里必有一格是对的 —— 在那格拍张照片即可（我直接看图判定）。
    //   ⚠ 不要用"按一次前进一格"的写法：它会把 load_cnt 的比较带进显示路径，
    //     实测会引出 12 条 hold 违例（TNS −12.19）。
    //   SEGCNT=0（正式版）永远用 rot1，不受影响。
    reg [27:0] rot_tmr;
    reg [1:0]  rot_sel;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rot_tmr <= 28'd0; rot_sel <= 2'd1; end
        else if (rot_tmr == 28'd150_000_000) begin      // 3 秒 @50MHz
            rot_tmr <= 28'd0;
            rot_sel <= (rot_sel == 2'd2) ? 2'd0 : (rot_sel + 2'd1);
        end else rot_tmr <= rot_tmr + 28'd1;
    end
    wire [23:0] rot0 = vout_raw;
    wire [23:0] rot1 = {vout_raw[7:0], vout_raw[23:16], vout_raw[15:8]};   // 原 RGB_ROT
    wire [23:0] rot2 = {vout_raw[15:8], vout_raw[7:0], vout_raw[23:16]};
    wire [23:0] vout_rot = !RGB_ROT ? rot0
                         : (SEGCNT ? ((rot_sel == 2'd0) ? rot0 :
                                      (rot_sel == 2'd1) ? rot1 : rot2)
                                   : rot1);
    wire [23:0] vout_rgb = vout_rot;
    reg         de_r, hs_r, vs_r;
    always @(posedge video_clk or posedge rst_all) begin
        if (rst_all) begin de_r <= 1'b0; hs_r <= 1'b1; vs_r <= 1'b1; end
        else begin de_r <= de; hs_r <= hs; vs_r <= vs; end
    end
    // ---- 板级自检 B：彩条。完全不经过 SDRAM，只验 HDMI 时序 + PHY + 显示器 ----
    // 5 条 128 像素宽的竖条（白/黄/青/绿/品红）。若这一版是噪点，
    // 说明问题在视频时序或 HDMI 链路，和 SDRAM、SD 卡都无关。
    reg [23:0] bar_rgb;
    always @(*) begin
        case (px[8:6])
            3'd0:    bar_rgb = 24'hFFFFFF;   // 白
            3'd1:    bar_rgb = 24'hFFFF00;   // 黄
            3'd2:    bar_rgb = 24'h00FFFF;   // 青
            3'd3:    bar_rgb = 24'h00FF00;   // 绿
            3'd4:    bar_rgb = 24'hFF00FF;   // 品红
            default: bar_rgb = 24'h000000;   // 黑
        endcase
    end

    // ---- 板级诊断 D：整屏纯色，报告读通路卡在哪一步（需要 DIAG=1）----
    //   红   = Sdr_init_done 一直没起来      -> SDRAM 初始化/时钟/IP 侧问题
    //   橙   = 初始化好了但读 FSM 从没启动    -> 触发链（line_tog/frame_tog）问题
    //   黄   = 读启动了但一行都没收满        -> SDRAM 读握手/地址问题
    //   绿   = 至少收满过一整行              -> 读通路是通的，问题在别处
    wire       diag_fetch_w, diag_line_w, diag_rsel_w;
    wire [3:0] diag_to_w;
    wire [3:0] diag_rot_w;
    wire [9:0] diag_lead_w;
    reg  [1:0] diag_s1, diag_s2;
    always @(posedge video_clk or posedge rst_all) begin
        if (rst_all) begin diag_s1 <= 2'd0; diag_s2 <= 2'd0; end
        else begin
            diag_s1 <= {diag_fetch_w, diag_line_w};
            diag_s2 <= diag_s1;
        end
    end
    wire [23:0] diag_rgb = !Sdr_init_done ? 24'hFF0000
                         : !diag_s2[1]    ? 24'hFF8000
                         : !diag_s2[0]    ? 24'hFFFF00
                                          : 24'h00FF00;

    // ---- 诊断 G：整屏颜色报告"扫描到几张图"（上电扫描完即可看，不需要按键）----
    //   红 = 0 张   橙 = 1 张（此时 K2 只会在第 0 张上打转、K4 完全没反应）
    //   黄 = 2 张   绿 = 3 张及以上
    wire [23:0] cnt_rgb = (img_total_w == 3'd0) ? 24'hFF0000
                        : (img_total_w == 3'd1) ? 24'hFF8000
                        : (img_total_w == 3'd2) ? 24'hFFFF00
                                                : 24'h00FF00;

    // ---- 诊断 H：报告"提交的缓冲区"与"显示实际在读的缓冲区"是否一致 ----
    //   disp_buf_idx = sd_card_bmp 提交的当前图片所在缓冲区
    //   rd_sel_v     = my_sdram_frame 显示侧真正在用的缓冲区
    //   红 (00) = 提交 0、显示读 0   —— 一致（按 K2 后若仍是红 => 提交没发生）
    //   黄 (01) = 提交 0、显示读 1   —— 不一致
    //   橙 (10) = 提交 1、显示读 0   —— 提交发生了但显示没跟着切（按 K2 后变橙 => 显示侧问题）
    //   绿 (11) = 提交 1、显示读 1   —— 一致
    wire [1:0]  buf_sel = {disp_buf_idx[0], diag_rsel_w};
    wire [23:0] buf_rgb = (buf_sel == 2'b00) ? 24'hFF0000
                        : (buf_sel == 2'b01) ? 24'hFFFF00
                        : (buf_sel == 2'b10) ? 24'hFF8000
                                             : 24'h00FF00;

    wire [23:0] vout = BUFCHK ? buf_rgb
                     : CNT  ? cnt_rgb
                     : DIAG ? diag_rgb
                     : BARS ? bar_rgb
                            : ((display_valid || SELFTEST) ? vout_rgb : 24'd0);   // 首图前黑屏

    // Audio is independent of TF loading; all HDMI inputs enter pixel_clk.
    wire audio_mclk, audio_pll_lock;
    wire audio_bclk, audio_lrck, audio_serial;
    wire audio_valid, acr_valid;
    wire [23:0] audio_left, audio_right;
    wire [19:0] acr_cts, acr_n;
    wire audio_async_rst = rst_all || !audio_pll_lock;
    reg [2:0] audio_rst_m, audio_rst_p;
    always @(posedge audio_mclk or posedge audio_async_rst) begin
        if(audio_async_rst) audio_rst_m <= 3'b111;
        else audio_rst_m <= {audio_rst_m[1:0],1'b0};
    end
    always @(posedge video_clk or posedge audio_async_rst) begin
        if(audio_async_rst) audio_rst_p <= 3'b111;
        else audio_rst_p <= {audio_rst_p[1:0],1'b0};
    end
    PLL_HDMI_AUDIO u_audio_pll(.refclk(clk),.reset(1'b0),.extlock(audio_pll_lock),
                              .clk0_out(),.clk1_out(),.clk2_out(audio_mclk));
    reg[1:0]music_pause_sync;
    always @(posedge audio_mclk or posedge rst_all)begin
        if(rst_all)music_pause_sync<=0;else music_pause_sync<={music_pause_sync[0],emergency_state[1]};
    end
    hdmi_audio_sine_i2s #(.PAUSE_ENABLE(1)) u_audio_tone(.I_mclk(audio_mclk),.I_rst(audio_rst_m[2]),.I_pause(music_pause_sync[1]),.I_music(settings_frame[17:16]),
        .O_i2s_BCLK(audio_bclk),.O_i2s_LRCK(audio_lrck),.O_i2s_DOUT(audio_serial));
    I2S_receiver u_audio_receiver(.I_clk(video_clk),.I_rst(audio_rst_p[2]),
        .I_i2s_BCLK(audio_bclk),.I_i2s_LRCK(audio_lrck),.I_i2s_DOUT(audio_serial),
        .O_audio_valid(audio_valid),.O_audio_left_data(audio_left),.O_audio_right_data(audio_right));
    audio_arc_calculate #(.ACR_N(6144)) u_acr(.I_clk(video_clk),.I_rst(audio_rst_p[2]),
        .I_audio_valid(hdmi_audio_valid),.O_acr_valid(acr_valid),.O_acr_cts(acr_cts),.O_acr_n(acr_n));

    wire hdmi_audio_valid;
    wire[23:0]hdmi_audio_left,hdmi_audio_right;
    wire[23:0]emergency_left,emergency_right,switch_left,switch_right;
    wire image_switch;
    picture_switch_sound u_switch_sound(.clk(video_clk),.rst(audio_rst_p[2]),
      .enable(settings_frame[18]&&emergency_frame_state==0),.trigger(image_switch),.valid(audio_valid),
      .left_in(audio_left),.right_in(audio_right),.left_out(switch_left),.right_out(switch_right));
    emergency_audio u_emergency_audio(.clk(video_clk),.rst(audio_rst_p[2]),.state(emergency_frame_state),
      .valid(audio_valid),.left_in(switch_left),.right_in(switch_right),
      .left_out(emergency_left),.right_out(emergency_right));
    wire[3:0]alert_volume=emergency_frame_state==2&&settings_frame[13:10]<4?4:settings_frame[13:10];
    player_audio_volume u_volume(.clk(video_clk),.rst(audio_rst_p[2]),
        .volume(alert_volume),.sound_on(settings_frame[14]||emergency_frame_state==2),
        .valid_in(audio_valid),.left_in(emergency_left),.right_in(emergency_right),
        .valid_out(hdmi_audio_valid),.left_out(hdmi_audio_left),.right_out(hdmi_audio_right));

    wire[23:0]adjusted_rgb;wire adjusted_de,adjusted_vs;
    player_picture_adjust u_picture_adjust(.clk(video_clk),.rst(rst_all),
        .config_word(settings_frame[15:0]),.rgb_in(vout),.de_in(de_r),.vs_in(vs_r),
        .rgb_out(adjusted_rgb),.de_out(adjusted_de),.vs_out(adjusted_vs));

    // Same PCM sample strobe feeds HDMI, ACR and analysis: no independent time base.
    wire [511:0] spectrum_levels;
    wire spectrum_update, spectrum_overrun;
    wire [23:0] spectrum_rgb;
    wire spectrum_de, spectrum_vs;
    // Pixel-domain analyzer shares the compositor reset. Audio startup is gated by PCM valid.
    pcm_spectrum_dft u_spectrum(.clk(video_clk),.rst(rst_all),
        .audio_valid(hdmi_audio_valid),.pcm_left(hdmi_audio_left),.levels(spectrum_levels),
        .update_valid(spectrum_update),.overrun(spectrum_overrun));
    hdmi_spectrum_overlay u_spectrum_overlay(.clk(video_clk),.rst(rst_all),
        .enable(settings_frame[15]&&!(SELFTEST||DIAG||BARS||CNT||BUFCHK)),
        .rgb_in(adjusted_rgb),.de_in(adjusted_de),.vs_in(adjusted_vs),.levels(spectrum_levels),.fault(spectrum_overrun),
        .rgb_out(spectrum_rgb),.de_out(spectrum_de),.vs_out(spectrum_vs));

    // Subtitle compositor delays pixel and DE/VS together by three cycles.
    wire [23:0] osd_rgb;
    wire osd_de,osd_vs;
    hdmi_subtitle_osd #(.SCROLL_ENABLE(1)) u_osd(.pause_scroll(emergency_state[1]),.scroll_enable(settings_frame[20]),.image_switch(image_switch),.clk(video_clk),.rst(rst_all),
        .enable(settings_frame[19]&&!(SELFTEST||DIAG||BARS||CNT||BUFCHK)),.rgb_in(spectrum_rgb),.de_in(spectrum_de),.vs_in(spectrum_vs),
        .image_total(img_total_w),.buffer0_size(osd_size0_w),.buffer1_size(osd_size1_w),
        .buffer0_image(osd_tag0_w),.buffer1_image(osd_tag1_w),
        .active_buffer(display_buf_ack_w[0]),.auto_mode_in(osd_auto_w),.image_valid_in(display_valid),
        .rgb_out(osd_rgb),.de_out(osd_de),.vs_out(osd_vs));

    // Emergency overlay retains priority over the optional small settings panel.
    wire[23:0]menu_rgb;wire menu_de,menu_vs;
    wire[23:0]settings_rgb;wire settings_de,settings_vs;
    wire settings_on_hdmi;
    wire[15:0]tft_chip_id;wire tft_ready,tft_fault;
    settings_display_router u_display_router(.clk(video_clk),.rst(rst_all),.sw1(sw1),
      .packet(settings_frame),.rgb_in(osd_rgb),.de_in(osd_de),.vs_in(osd_vs),
      .rgb_out(settings_rgb),.de_out(settings_de),.vs_out(settings_vs),.hdmi_active(settings_on_hdmi),
      .lcd_db(tft_data),.lcd_cs_n(tft_cs_n),.lcd_rs(tft_rs),.lcd_wr_n(tft_wr_n),
      .lcd_rd_n(tft_rd_n),.lcd_rst_n(tft_rst_n),.lcd_bl(tft_bl),
      .chip_id(tft_chip_id),.ready(tft_ready),.fault(tft_fault));
    emergency_overlay u_emergency_overlay(.clk(video_clk),.rst(rst_all),
      .state(emergency_state),.seconds(emergency_seconds),.blink_warning(emergency_warn_blink),.blink_emergency(emergency_red_blink),
      .rgb_in(settings_rgb),.de_in(settings_de),.vs_in(settings_vs),
      .rgb_out(menu_rgb),.de_out(menu_de),.vs_out(menu_vs),.frame_state(emergency_frame_state));

    // ---- AXIS + HDMI ----
    wire axis_s_user, axis_s_valid, axis_s_last, axis_s_ready;
    wire [23:0] axis_s_data;
    video_rgb_to_axis_640x480 u_axis (
        .I_clk(video_clk), .I_rst(rst_all), .I_vs(menu_vs), .I_de(menu_de), .I_rgb(menu_rgb),
        .O_video_user(axis_s_user), .O_video_valid(axis_s_valid),
        .O_video_last(axis_s_last), .O_video_data(axis_s_data)
    );

    wire edid_trig, edid_valid; wire [7:0] edid_data;
    startup_pulse #(.CNT_MAX(20'd100000)) u_startup_pulse (
        .I_clk(video_clk), .I_rst(rst_all), .O_pulse(edid_trig)
    );

    wire [9:0] tmds_ch0, tmds_ch1, tmds_ch2, tmds_clk;
    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE("EG"), .HTOTAL(800), .HSA(96), .HFP(16), .HBP(48), .HACTIVE(640),
        .VTOTAL(525), .VSA(2), .VFP(10), .VBP(33), .VACTIVE(480),
        .VIDEO_VIC(1), .VIDEO_TPG("Disable"), .VIDEO_FORMAT("RGB"),
        .AUDIO_SAMPLE_RATE("48K"), .IIC_SCL_DIV(250)
    ) u_hdmi (
        .I_pixel_clk(video_clk), .I_rst(rst_all),
        .I_edid_read_trig(edid_trig), .O_edid_read_valid(edid_valid), .O_edid_read_data(edid_data),
        .I_axis_s_user(axis_s_user), .I_axis_s_valid(axis_s_valid),
        .I_axis_s_last(axis_s_last), .I_axis_s_data(axis_s_data), .O_axis_s_ready(axis_s_ready),
        .I_audio_valid(hdmi_audio_valid), .I_audio_left_data(hdmi_audio_left), .I_audio_right_data(hdmi_audio_right),
        .I_acr_valid(acr_valid), .I_acr_cts(acr_cts), .I_acr_n(acr_n),
        .O_video_locked(), .O_ddc_scl(HDMI_DDC_SCL), .IO_ddc_sda(HDMI_DDC_SDA),
        .O_ch0_tmds_data(tmds_ch0), .O_ch1_tmds_data(tmds_ch1),
        .O_ch2_tmds_data(tmds_ch2), .O_clk_tmds_data(tmds_clk)
    );

    hdmi_phy_wrapper #(.DEVICE("EG")) u_phy (
        .I_pixel_clk(video_clk), .I_serial_clk(hdmi_5x_clk), .I_rst(rst_all),
        .I_tmds_channel_0(tmds_ch0), .I_tmds_channel_1(tmds_ch1),
        .I_tmds_channel_2(tmds_ch2), .I_tmds_channel_clk(tmds_clk),
        .O_tmds_ch0_p(HDMI_D0_P), .O_tmds_ch1_p(HDMI_D1_P),
        .O_tmds_ch2_p(HDMI_D2_P), .O_tmds_clk_p(HDMI_CLK_P)
    );

    // ---- 数码管：state_code + （SEGCNT=1 时）加载次数/提交次数 ----
    //   load_cnt   = write_req 上升沿次数 = 发起过几次整帧加载
    //   commit_cnt = disp_buf_idx 变化次数 = 提交过几次（显示缓冲区真的切过几次）
    //   按一次 KEY2 后的读法：
    //     两个都 +1   => 整链正常，问题在显示/图像内容
    //     只有 load 变 => 写侧没提交（看 sim/tb_write_path2.v 与 SD 流）
    //     两个都不变   => 按键或加载没发起
    reg [3:0] load_cnt, commit_cnt, hdr_cnt;
    reg       sd_wr_req_d, dispbuf_d;
    reg [3:0] state_code_d;
    reg       disp_valid_d;
    reg       st2_stuck;                        // 首图之后"取头卡住"（state 2 连续 >50ms）标志
    reg [22:0] st2_cnt;
    always @(posedge sd_card_clk or posedge rst_all) begin
        if (rst_all) begin
            sd_wr_req_d <= 1'b0;
            load_cnt    <= 4'd0;
        end else begin
            sd_wr_req_d <= sd_wr_req;
            if (sd_wr_req && !sd_wr_req_d) load_cnt <= load_cnt + 4'd1;
        end
    end
    // 提交次数：数 display_valid 的上升沿（第一张图落在 BUF0，disp_buf_idx 不变，
    // 所以不能用"disp_buf_idx 变化"来数提交 —— 那会漏掉第一次）
    always @(posedge sd_card_clk or posedge rst_all) begin
        if (rst_all) begin
            disp_valid_d <= 1'b0;
            commit_cnt   <= 4'd0;
        end else begin
            disp_valid_d <= display_valid;
            if (display_valid && !disp_valid_d) commit_cnt <= commit_cnt + 4'd1;
        end
    end
    // 取头/扫描次数：state_code == 2 的上升沿（1 次扫描 + 每次取头各算一次）
    always @(posedge sd_card_clk or posedge rst_all) begin
        if (rst_all) begin
            state_code_d <= 4'd0;
            hdr_cnt      <= 4'd0;
        end else begin
            state_code_d <= state_code;
            if ((state_code == 4'd2) && (state_code_d != 4'd2)) hdr_cnt <= hdr_cnt + 4'd1;
        end
    end
    // "卡住"检测：首图显示之后，state_code 连续 50ms 停在 2（= 扇区读没回来，SD 控制器卡在 CMD17）
    always @(posedge sd_card_clk or posedge rst_all) begin
        if (rst_all) begin
            st2_cnt   <= 23'd0;
            st2_stuck <= 1'b0;
        end else if (!display_valid) begin
            st2_cnt   <= 23'd0;                 // 首图之前的扫描阶段不算
        end else if (state_code == 4'd2) begin
            if (st2_cnt != 23'd8_388_607) st2_cnt <= st2_cnt + 23'd1;
            if (st2_cnt >= 23'd5_000_000) st2_stuck <= 1'b1;   // 50ms @100MHz
        end else begin
            st2_cnt <= 23'd0;
        end
    end
    // 本帧已经送进 FIFO 的字数（= SD 侧 write_en 脉冲数）。
    //   整帧到 20'h4B000=307200 => 高 4 位 [18:15] = 9；所以数码管显示 9 = 整帧送完。
    //   若某次加载停在 3/5/7 之类的数，说明 SD 流在中途断了（配合 1 秒超时）。
    reg [19:0] frame_word_cnt;
    always @(posedge sd_card_clk or posedge rst_all) begin
        if (rst_all) frame_word_cnt <= 20'd0;
        else if (sd_wr_req && !sd_wr_req_d) frame_word_cnt <= 20'd0;
        else if (sd_wr_en && (frame_word_cnt != 20'd307200))
            frame_word_cnt <= frame_word_cnt + 20'd1;
    end
    always @(posedge sd_card_clk or posedge rst_all) begin
        if (rst_all) begin
            dispbuf_d   <= 1'b0;
        end else begin
            dispbuf_d <= disp_buf_idx[0];
        end
    end
    wire [6:0] seg_load, seg_commit, seg_wcnt, seg_rfto, seg_hdr, seg_stuck;
    wire [6:0] seg_s2, seg_s1, seg_s0, seg_b0, seg_b1;
    reg  [3:0] seg_wcnt_hi;
    always @(*) seg_wcnt_hi = frame_word_cnt[18:15];
    // 【第三轮诊断】取头读到的头两字节是否是 'B' 'M'（正常=1）
    wire [3:0] dbg_b0 = (dbg_hdr0_w == 8'h42) ? 4'd1 : 4'd0;
    wire [3:0] dbg_b1 = (dbg_hdr1_w == 8'h4D) ? 4'd1 : 4'd0;
    seg_decoder u_seg_load   (.bin_data(load_cnt),     .seg_data(seg_load));
    seg_decoder u_seg_commit (.bin_data(commit_cnt),   .seg_data(seg_commit));
    seg_decoder u_seg_wcnt   (.bin_data(seg_wcnt_hi),  .seg_data(seg_wcnt));
    seg_decoder u_seg_rfto   (.bin_data(diag_to_w),    .seg_data(seg_rfto));
    seg_decoder u_seg_hdr    (.bin_data(hdr_cnt),      .seg_data(seg_hdr));
    seg_decoder u_seg_stuck  (.bin_data({3'b000, st2_stuck}), .seg_data(seg_stuck));
    seg_decoder u_seg_s2     (.bin_data(dbg_sector_w[11:8]),  .seg_data(seg_s2));
    seg_decoder u_seg_s1     (.bin_data(dbg_sector_w[7:4]),   .seg_data(seg_s1));
    seg_decoder u_seg_s0     (.bin_data(dbg_sector_w[3:0]),   .seg_data(seg_s0));
    seg_decoder u_seg_b0     (.bin_data(dbg_b0),              .seg_data(seg_b0));
    seg_decoder u_seg_b1     (.bin_data(dbg_b1),              .seg_data(seg_b1));
    // 环移扫描诊断时，把当前 rot 值显示出来（4 位补码：0..9,a..f 表示 0..15，
    // f/e/d/… 表示 -1/-2/-3…）
    wire [6:0] seg_rot;
    seg_decoder u_seg_rot    (.bin_data(diag_rot_w),          .seg_data(seg_rot));

    wire [6:0] seg_code;
    seg_decoder seg_decoder_m0 (.bin_data(state_code), .seg_data(seg_code));

    // =====================================================================
    // 【wrkey 诊断（SEGCNT=1）】数码管 6 位读数
    //   物理位置：本设计只驱动 seg_sel[5:0]（= 板上 SEL2..SEL7，从左数是第 3..8 位），
    //   所以点亮的正好是 6 位。用户实测确认：**最左那位就是 seg_data_0**。
    //   ⚠ 自校准图案（上电显示 123456）**已删除**：板级出现过"它一直不退出、
    //     数码管什么都读不到"的情况（等于把仪表本身变成盲点）。
    //     seg_data_0 = 本帧已送进 FIFO 的字数高位（**9 = 满帧 307200 ✓**；0/1 = 几乎没数据
    //                  ⇒ 白屏/空帧就是这种情况）
    //     seg_data_1 = 本次加载的目标扇区 [7:4]（4 => 扇区 8256；8 => 10112；0 => 空条目）
    //     seg_data_2 = 提交次数（display_valid 上升沿次数）
    //     seg_data_3 = 加载次数（write_req 上升沿次数）
    //     seg_data_4 = 扫描到的图片张数
    //     seg_data_5 = state_code（平时只亮的那一位，1/2/3/4）
    // =====================================================================
    wire [6:0] seg_sec, seg_imgn;
    seg_decoder u_seg_sec    (.bin_data(dbg_sector_w[7:4]),   .seg_data(seg_sec));
    seg_decoder u_seg_imgn   (.bin_data(img_total_w), .seg_data(seg_imgn));

    seg_scan seg_scan_m0 (
        .clk(clk), .rst_n(rst_n), .seg_sel(seg_sel), .seg_data(seg_data),
        .seg_data_0({1'b1, SEGCNT ? seg_wcnt   : 7'b111_1111}),   // 本帧字数高位（9=满帧）
        .seg_data_1({1'b1, SEGCNT ? seg_sec    : 7'b111_1111}),   // 目标扇区 [7:4]
        .seg_data_2({1'b1, SEGCNT ? seg_commit : 7'b111_1111}),   // 提交次数
        .seg_data_3({1'b1, SEGCNT ? seg_load   : 7'b111_1111}),   // 加载次数
        .seg_data_4({1'b1, SEGCNT ? seg_imgn   : 7'b111_1111}),   // 扫描到的张数
        .seg_data_5({1'b1, ROTSWEEP ? seg_rot  : seg_code})       // state
    );

endmodule


// ============================================================================
//  sd_card_bmp 需要的一处改动（满足"KEY2 开始读取 + 首图前黑屏"）
//
//  删掉"上电自动加载首图"分支（它是加载 else-if 链的第一条）：
//      if (scan_done && !first_image_committed && bmp_ready && !load_busy && (img_found_count != 3'd0))
//  删掉之后，加载只由 next_req_pending（KEY2）驱动：
//      上电 → 扫描（数码管 2）→ 扫描完 IDLE（数码管 1）→ 黑屏等按键 ✓
//      KEY2 → 加载 → 提交 → 出图 ✓ 再按 KEY2 → 搜下一张 ✓
//
//  SCAN_TARGET_COUNT 已在顶层例化处设为 2 ✓
// ============================================================================
