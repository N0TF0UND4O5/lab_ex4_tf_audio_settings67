module bmp_read_reference #(parameter FLEXIBLE_BMP=0)(
    input                       pixel_ready,
    input [31:0]                direct_width,direct_height,
    output [15:0]               source_width,source_height,
    output                      source_top_down,
    output reg [31:0]           o_scan_width,o_scan_height,
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [3:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [3:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input                       load_abort,
    input  [31:0]               load_sector,
    // 【按键切图·可信直载】取头校验失败时的兜底：
    //   扫描阶段已经**校验过**这个扇区确实是合法 BMP 头，并把 file_len / pixel_offset
    //   解析出来了（由 sd_card_bmp 存表）。板级实测：切第二张时那个扇区的取头会
    //   **确定性**地读到错位数据（30 次重试全失败），而同一扇区在扫描时是读得对的
    //   —— 所以"多试几次"救不了；改为直接按表里的信息进数据相位（跳过取头校验）。
    input                       load_direct,
    input  [31:0]               direct_file_len,
    input  [31:0]               direct_pixel_offset,

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data,

    // 【第三轮诊断】把最近一次"取头"解析出来的头两个字节送出来给数码管看：
    //   正常 BMP 应该是 0x42('B') / 0x4D('M')。若看到的不是这两个值，
    //   说明那一次扇区读回来的数据根本不是 BMP 头（地址不对/数据错位）。
    output [7:0]                o_header_0,
    output [7:0]                o_header_1,

    // 【横向偏移根治】每次加载由"第一个数据扇区实收字节数"算出的"帧首补黑条数"。
    //   ⚠ 板级实测（2026-10-06 晚）：这项**测出来是 0**，而图像仍然整体偏移 —— 因为那次
    //   扇区读是"内容错位、字节数不少"（抓错了数据起始令牌），字节计数根本看不出来。
    //   所以正常构建**不用它补偿**（写侧 LEAD_USE_MEAS=0，用固定 172），这里只当接口/诊断。
    output reg [9:0]            o_lead_words,
    output reg                  o_lead_valid,
    // 【诊断】扫描看门狗超时脉冲：一次扫描读超过 SCAN_TO_CYCLES 没回来就报一次
    output                      o_scan_timeout,
    // 【横向偏移根治 v2 诊断】第一个数据扇区"内容错位"的检测次数（饱和到 f）。
    //   板上看到 >=1 就说明"抓错令牌"确实在发生 —— 这就是那个 ~170 像素偏移的真因。
    output      [3:0]           o_sec_fix_cnt,
    // 【按键切图·可信直载】扫描命中那一刻**锁存**下来的 file_len / pixel_offset
    //   （必须锁存：头字段在 read_end 的下一拍就被清掉了，上层那一拍才采样 scan_found_valid）
    output reg [31:0]           o_scan_file_len,
    output reg [31:0]           o_scan_pixel_offset
);

assign o_header_0 = header_0;
assign o_header_1 = header_1;
assign o_sec_fix_cnt = sec_fix_cnt;

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;
// 【第三轮加固】扫描命中后先复读同一扇区确认一次，防"偶发误匹配"。
//   ⚠ 目前**没有启用**：板级证明真实 SD 扇区读本身就会偶发失败，要求"两次都命中"
//   会把真图也全否掉（图片表变空 ⇒ K2/K4 全无反应）。保留状态码供以后使用。
localparam ST_SCAN_VRFY = 3'd5;
// 【按键切图·热身】加载开始先做一次"丢弃式"扇区读。
//   板级规律（三条证据合起来）：**隔开一段时间后的第一次扇区读会错位**，而紧接着
//   连读的扇区不会 —— 扫描阶段是连读（两张图都读对了 ✓）、数据相位除第一条之外都
//   正常 ✓、"孤立"的那条永远错 ✗。所以关键读之前先热身一次：
//     [热身读(丢弃)] → [取头读] → [数据相位读] 全部变成"连读"
//   热身读的数据一个字都不采（FSM 停在 ST_LOAD_WARM，计数器只在 ST_LOAD_DATA 里动）。
localparam ST_LOAD_WARM = 3'd6;
// 【取头读复用】把取头读回来的 512 字节重放出去（像素部分）——见文件末尾说明。
localparam ST_LOAD_REPLAY = 3'd7;
localparam ST_LOAD_CHECK = 4'd8;
localparam ST_LOAD_NEXT = 4'd9;

// ---- 【扫描看门狗】板级踩过的坑 ----
//   现象：连续折腾几次之后 K1 复位，数码管停在"扫描中(state=2)、一张图都没找到"，
//   按 K2 永远没反应 —— 因为**扫描阶段没有超时**：只要某一次扇区读不返回
//   （卡被上一次中止的读留在半途），ST_SCAN 就永远等不到 read_end，
//   scan_done 永远是 0 ⇒ 加载分支永远不成立 ⇒ 按键彻底失效。
//   这里加看门狗：一次扫描读超过 SCAN_TO_CYCLES（约 30ms，正常一次扇区读 ~200µs）
//   就抬 o_scan_timeout，由 sd_card_bmp **重启 SD 控制器并重新开始扫描**。
localparam [26:0] SCAN_TO_CYCLES = 27'd3_000_000;   // 30 ms @100MHz

// ---- 【按键可靠性】取头失败时的"就地重试" ----
//   板级实测：每次加载的第一个扇区读经常是坏的/没读到（"第一次读失败、重试就好"）。
//   原来一次取头失败就回 IDLE、等上层 1 秒超时再重来 —— 用户按 K2 后要等 2 秒多
//   才有反应，多次按键还会互相打断，表现就是"按键没反应"。
//   现在在 ST_LOAD_HDR 里就地重读同一个扇区，全程对上层不可见。
//   【本轮】次数 8→30、间隔 2ms→1ms（约 30ms 连续重试窗口）：板级现象是第二张
//   （扇区 10112）的取头会连续失败 —— 抓错令牌是**随机**的，"多试几次、试得快一点"
//   比"干等 1 秒的外层超时"有效得多。
localparam [4:0]  HDR_RETRY_MAX  = 5'd30;
localparam [17:0] HDR_RETRY_WAIT = 18'd100_000;      // 1 ms @100MHz

reg [3:0]  state;
wire loading_phase=(state==ST_LOAD_DATA)||(state==ST_LOAD_REPLAY)||
                   (state==ST_LOAD_CHECK)||(state==ST_LOAD_NEXT);
reg [9:0]  rd_cnt;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] width;
reg [31:0] height;
reg [15:0] bit_count;
reg [31:0] compression;

reg [31:0] scan_sector;
reg [31:0] load_sector_latched;
reg [31:0] bmp_len_cnt;
reg [1:0]  bmp_byte_idx;
reg [4:0]  hdr_retry;          // 取头重试次数（5 位：最多 30 次）
reg [17:0] hdr_wait;           // 取头重试间隔倒计时
// 【重要】头字段只能在这一个 always 块里驱动（TD 会报 HDL-8007 多驱动）。
//   所以 FSM 想清头字段时不能直接赋值，只能抬一个"请清"的标志，由本块统一执行。
reg        hdr_clr;
// 【取头读复用】1 = 这次加载真的做过取头校验（⇒ 缓存里有对齐的 512 字节可重放）。
//   直载路径没读过头 ⇒ 没有缓存 ⇒ 只能按老办法直接读数据相位。
wire       use_replay = ~load_direct;
// 【按键切图·可信直载】把表里的 file_len/pixel_offset 预装进头字段（1 拍请求）
reg        hdr_preload;
reg [31:0] pre_file_len;
reg [31:0] pre_pixel_offset;

// ---- 【横向偏移根治】第一个数据扇区的实测与"错位检测" ----
reg [9:0]  sec_byte_cnt;       // 当前数据扇区已收到的字节数（完整应为 512）
reg        first_data_sec;     // 当前数据扇区是本帧的第一个（只对它做检测）
reg        sec_clr;            // FSM 请求"扇区计数归零"（只能由计数块执行，防多驱动）
reg        data_rst;           // FSM 请求"整段数据计数归零"（同上）
reg        sec_bad;            // 本次读到的第一个数据扇区"内容错位"
reg [3:0]  sec_fix_try;        // 已丢弃重读次数（本轮 SEC_FIX_EN=0，恒 0）
reg [3:0]  sec_fix_cnt;        // 诊断：错位检测次数（饱和）
reg [17:0] sec_fix_wait;       // 丢弃重读的间隔倒计时（本轮不启用）
reg        cnt_clr;            // FSM 请求"错位计数归零"（只能由计数块执行，防多驱动）
// 【扫描看门狗】一次扫描读的计时（SD 时钟域）
reg [26:0] scan_to_cnt;
reg        scan_to_r;
// ---- 【取头读复用】取头那次读的 512 字节缓存 + 重放计数 ----
reg [7:0]  hdr_buf [0:511];
reg [9:0]  rp_cnt;
// 重放开始时要把 bmp_len_cnt 预置成 pixel_offset（只能由计数块执行，防多驱动）
reg        len_set;
reg [9:0]  len_set_val;

assign o_scan_timeout = scan_to_r;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        scan_to_cnt <= 27'd0;
        scan_to_r   <= 1'b0;
    end else if ((state == ST_SCAN) || (state == ST_SCAN_VRFY)) begin
        scan_to_r <= 1'b0;
        if (sd_sec_read_end) begin
            scan_to_cnt <= 27'd0;
        end else if (scan_to_cnt != SCAN_TO_CYCLES) begin
            scan_to_cnt <= scan_to_cnt + 27'd1;
        end else begin
            scan_to_r   <= 1'b1;      // 单拍脉冲：这一读超时了
            scan_to_cnt <= 27'd0;
        end
    end else begin
        scan_to_cnt <= 27'd0;
        scan_to_r   <= 1'b0;
    end
end

wire header_match;
reg header_match_q;
reg [31:0] header_expected_end, header_len_lo, header_len_hi;
wire bmp_data_valid;
reg [31:0] file_sector_count;
reg [31:0] next_scan_sector_if_match;
wire [31:0] next_scan_sector_if_miss;
// 一帧像素数据的字节数（按当前目标分辨率算，仿真里用 64x48 也能过）
wire[31:0]absolute_height=height[31]?(~height+32'd1):height;
assign source_width=FLEXIBLE_BMP?width[15:0]:bmp_width;
assign source_height=FLEXIBLE_BMP?absolute_height[15:0]:bmp_height;
assign source_top_down=FLEXIBLE_BMP&&height[31];
reg[13:0]row_bytes,row_stride;reg[25:0]pixel_bytes;
reg[13:0]row_byte_position;
wire[31:0]bmp_pixel_bytes=FLEXIBLE_BMP?pixel_bytes:bmp_width*bmp_height*16'd3;
always @(posedge clk)begin
 row_bytes<=width[11:0]*14'd3;row_stride<=(width[11:0]*14'd3+14'd3)&14'h3ffc;
 pixel_bytes<=row_stride*absolute_height[11:0];
end
wire replay_ready=!FLEXIBLE_BMP||pixel_ready;
wire image_byte=(byte_evt&&bmp_len_cnt>=pixel_offset&&bmp_len_cnt<pixel_offset+bmp_pixel_bytes);
always @(posedge clk or posedge rst)begin
 if(rst)row_byte_position<=0;
 else if(!loading_phase||data_rst)row_byte_position<=0;
 else if(image_byte)row_byte_position<=row_byte_position==row_stride-1?0:row_byte_position+1'b1;
end
always @(posedge clk or posedge rst)begin
 if(rst)begin o_scan_width<=0;o_scan_height<=0;end
 else if(state==ST_SCAN&&sd_sec_read_end&&header_match)begin o_scan_width<=width;o_scan_height<=height;end
end

// ===========================================================================
// 【横向偏移根治 v2】"内容错位、字节数不少"的检测（板上实测的真因）
//
//   板级读数（wrkey.bit）：数码管"实测补黑条数 = 0"（第一个数据扇区完整 512 字节、
//   写侧整帧也写满）**却**图像整体左偏 ~170 像素。两者同时成立只有一个解释：
//   那一次扇区读**抓错了数据起始令牌**（SPI 上先把某个 0xFE 当成数据起点），
//   交回来的是"从中间某处开始"的字节、**字节数照样是 512**。
//   （这也顺带解释了"取头老要重试几次"：错位那次的 header_match 当然不过。）
//
//   检测办法：数据相位的**第一个扇区就是头部扇区**，它的前 6 个字节是已知的
//   （'B','M' + file_len 的 4 个字节，取头相位已经解析出来）⇒ 逐字节比对，
//   对不上就是这个扇区读错位了。本拍只**计数**（o_sec_fix_cnt 送数码管）；
//   是否"丢弃重读"由 SEC_FIX_EN 决定（见下）。
// ===========================================================================
localparam [3:0]  SEC_FIX_MAX  = 4'd8;
localparam [17:0] SEC_FIX_WAIT = 18'd200_000;        // 2 ms @100MHz
// 【本轮】1 = 检测到错位就丢弃重读（此时一个像素都没发出，丢弃零损失）。
//   ⚠ 板级实测过这一版：错位确实被抓到（数码管显示 2 次），但"同一扇区连着读第二次"
//   本身就是触发错位的原因 —— 丢弃重读会让**下一个扇区**又错位，位置反而没救；
//   而且它改变了已经板级验证过的数据通路。所以本轮关掉（= 数据通路与 wrfix13 完全一致），
//   只保留检测计数；偏移继续由写侧固定补黑 WR_LEAD=172 负责（见《交接_颜色与位置.md》）。
localparam        SEC_FIX_EN   = 1'b0;
// ---- 【取头读复用】统一的"字节事件"：数据相位来自 SD，重放相位来自取头缓存 ----
wire       replay_on  = (state == ST_LOAD_REPLAY);
wire       byte_evt   = replay_on ? ((rp_cnt >= pixel_offset[9:0])&&replay_ready)
                                  : ((state == ST_LOAD_DATA) && sd_sec_read_data_valid);
wire [7:0] byte_val   = replay_on ? hdr_buf[rp_cnt[8:0]] : sd_sec_read_data;

// 第一个数据扇区前 6 个字节"应该"是什么（与取头相位解析出来的一致）
wire [7:0] sec_exp_b = (sec_byte_cnt == 10'd0) ? 8'h42 :        // 'B'
                       (sec_byte_cnt == 10'd1) ? 8'h4D :        // 'M'
                       (sec_byte_cnt == 10'd2) ? file_len[7:0]  :
                       (sec_byte_cnt == 10'd3) ? file_len[15:8] :
                       (sec_byte_cnt == 10'd4) ? file_len[23:16]:
                       (sec_byte_cnt == 10'd5) ? file_len[31:24]: 8'h00;
wire       sec_expect_en = first_data_sec && (sec_byte_cnt <= 10'd5);
// 缺字换算（接口/诊断用）：第一个数据扇区实收 B 字节 ⇒ 缺 (512-B) 字节 ⇒ 缺 (512-B)/3 个字
//   （每 3 字节 1 个像素字）。用 171/512 的定点近似做除 3，对 3 的整数倍是精确的。
//   ⚠ 位宽：512×171 = 87552 需要 17 位；若让 Verilog 按 10 位算会被静默截断！
wire [9:0]  lead_def_bytes = 10'd512 - sec_byte_cnt;
wire [16:0] lead_calc      = (({7'd0, lead_def_bytes} * 17'd171) + 17'd256) >> 9;

assign ready = (state == ST_IDLE);
// Validate only a complete sector; pipeline arithmetic instead of chaining it
// with scan address addition in the 100 MHz state transition.
reg header_complete_q;
always @(posedge clk or posedge rst)begin
 if(rst)header_complete_q<=0;
 else header_complete_q<=((state==ST_SCAN)||(state==ST_LOAD_HDR)||(state==ST_SCAN_VRFY))&&
                          !sd_sec_read_end&&(sd_sec_read_data_valid?(rd_cnt==10'd511):(rd_cnt==10'd512));
end
// Predict the updated byte count on the final data edge, then consume the
// registered completion on read_end. No counter decode cascades into address
// selection, and short/overlong sectors cannot borrow a previous header.
assign header_match = header_match_q && (FLEXIBLE_BMP?header_complete_q:(rd_cnt == 10'd512));
always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_match_q <= 1'b0;
        header_expected_end <= 0;
        header_len_lo <= 0;
        header_len_hi <= 0;
    end else begin
        header_expected_end <= pixel_offset + bmp_pixel_bytes;
        header_len_lo <= FLEXIBLE_BMP?header_expected_end:(header_expected_end>4096?header_expected_end-4096:0);
        header_len_hi <= header_expected_end + 32'd4096;
header_match_q <= (header_0 == "B") &&
                      (header_1 == "M") &&
                      (FLEXIBLE_BMP?(width>=1&&width<=2048&&((height>=32'd1&&height<=32'd2048)||height>=32'hfffff800)&&pixel_offset>=54&&pixel_offset<512):
                       (width[15:0]==bmp_width&&height[15:0]==bmp_height)) &&
                      (bit_count    == 16'd24) &&
                      (compression  == 32'd0) &&
                      // 【第三轮加固】file_len 必须与 640x480x24 相符（±4KB 容差）。
                      // 板上实测：扫描把"已删除图片的物理残留"也当成了图片（扇区 46，
                      // 取头读回来根本不是 BMP 头），于是图片表里混进假条目、真正的第二张
                      // 反而没进表。加上这条能把"尺寸不一样的老残留"挡掉。
                      (file_len >= header_len_lo) &&
                      !(file_len > header_len_hi);
    end
end
assign bmp_data_valid = (byte_evt == 1'b1) &&
                        (bmp_len_cnt >= pixel_offset) &&
                        (bmp_len_cnt < file_len) && (!FLEXIBLE_BMP||(bmp_len_cnt<pixel_offset+bmp_pixel_bytes&&row_byte_position<row_bytes));
always @(posedge clk or posedge rst) begin
    if (rst) begin file_sector_count <= 1; next_scan_sector_if_match <= 0; end
    else begin
        file_sector_count <= (file_len == 0) ? 32'd1 : ((file_len + 32'd511) >> 9);
        next_scan_sector_if_match <= scan_sector + file_sector_count;
    end
end
assign next_scan_sector_if_miss  = scan_sector + 32'd1;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR) || (state == ST_SCAN_VRFY)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR) || (state == ST_SCAN_VRFY)) && sd_sec_read_data_valid) begin
        // 【取头读复用】顺手把这一个扇区的 512 字节全缓存下来（重放时用）
        if (rd_cnt <= 10'd511) hdr_buf[rd_cnt[8:0]] <= sd_sec_read_data;

        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;

            10'd10: pixel_offset[7:0] <= sd_sec_read_data;
            10'd11: pixel_offset[15:8] <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0] <= sd_sec_read_data;
            10'd31: compression[15:8] <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
    end else if (((state == ST_SCAN) || (state == ST_SCAN_VRFY)) && sd_sec_read_end) begin
        // 每扫完一个扇区就把头字段清空。
        // 这样下一个扇区即使一个字节都没收到，也不会沿用上一张图的合法头
        // 而被 header_match 误判成"命中"（原来的隐患）。
        // 用非阻塞赋值，所以 read_end 那一拍对 header_match 的判定仍然使用
        // 本扇区刚刚解析出来的值，不会影响本次判定。
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
    end else if (hdr_preload) begin
        // 【按键切图·可信直载】扫描阶段已经校验过这个扇区，直接把表里的两个字段装上，
        //   然后跳过取头校验直接进数据相位（头 magic/尺寸等不再重新判）。
        file_len     <= pre_file_len;
        pixel_offset <= pre_pixel_offset;
        if(FLEXIBLE_BMP)begin width<=direct_width;height<=direct_height;end
    end else if (hdr_clr) begin
        // FSM 请求"清头"（取头失败要重试同一扇区时）：清干净，
        // 这样重试那次即使一个字节都没读回来，也不会拿残留字段误判成命中。
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
    end
end

// 数据相位的字节计数 + 【横向偏移根治 v2】第一个扇区的错位检测
always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt  <= 32'd0;
        sec_byte_cnt <= 10'd0;
        sec_bad      <= 1'b0;
        sec_fix_cnt  <= 4'd0;
    end else if (cnt_clr) begin
        // FSM 请求：本次加载的错位计数从 0 开始（sec_fix_cnt 只能在这一个块里赋值）
        sec_fix_cnt  <= 4'd0;
    end else if (!loading_phase || data_rst) begin
        bmp_len_cnt  <= 32'd0;
        sec_byte_cnt <= 10'd0;
        sec_bad      <= 1'b0;
    end else if (len_set) begin
        // 【重放起点对齐】把字节计数预置成 pixel_offset（与 rp_cnt 同步，防相位错位）
        bmp_len_cnt <= {12'd0, len_set_val};
    end else if (sec_clr) begin
        // FSM 在扇区读完那一拍抬 sec_clr：本扇区计数归零，下一扇区重新数
        //（这些计数器只能在这一个块里赋值，否则 TD 报 HDL-8007 多驱动）
        sec_byte_cnt <= 10'd0;
    end else if (byte_evt) begin
        if (sec_expect_en && (byte_val != sec_exp_b)) begin
            sec_bad <= 1'b1;
            if (sec_fix_cnt != 4'hf) sec_fix_cnt <= sec_fix_cnt + 4'd1;
        end
        if (!(sec_bad && SEC_FIX_EN)) begin
            // ⚠ 只有"真的会丢弃重读"（SEC_FIX_EN=1）时才冻结计数；
            //   本轮 SEC_FIX_EN=0 时计数照常走 —— 数据通路与 wrfix13 **完全一致**。
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
            if (sec_byte_cnt != 10'd512) sec_byte_cnt <= sec_byte_cnt + 10'd1;
        end
    end
end
always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_byte_idx <= 2'd0;
    end else if (loading_phase) begin
        if (bmp_data_valid)
            bmp_byte_idx <= (bmp_byte_idx == 2'd2) ? 2'd0 : (bmp_byte_idx + 2'd1);
    end else begin
        bmp_byte_idx <= 2'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en <= 1'b0;
        bmp_data       <= 24'd0;
    end else if (loading_phase) begin
        if (bmp_data_valid) begin
            case (bmp_byte_idx)
                2'd0: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[7:0]  <= byte_val;
                end
                2'd1: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[15:8] <= byte_val;
                end
                2'd2: begin
                    bmp_data_wr_en  <= 1'b1;
                    bmp_data[23:16] <= byte_val;
                end
                default: begin
                    bmp_data_wr_en <= 1'b0;
                end
            endcase
        end else begin
            bmp_data_wr_en <= 1'b0;
        end
    end else begin
        bmp_data_wr_en <= 1'b0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 4'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        hdr_retry         <= 5'd0;
        hdr_wait          <= 18'd0;
        hdr_clr           <= 1'b0;
        first_data_sec    <= 1'b0;
        o_lead_words      <= 10'd0;
        o_lead_valid      <= 1'b0;
        sec_fix_try       <= 4'd0;
        sec_fix_wait      <= 18'd0;
        data_rst          <= 1'b0;
        cnt_clr           <= 1'b0;
        rp_cnt            <= 10'd0;

    end else if (!sd_init_done) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 4'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        hdr_retry         <= 5'd0;
        hdr_wait          <= 18'd0;
        hdr_clr           <= 1'b0;
        first_data_sec    <= 1'b0;
        o_lead_words      <= 10'd0;
        o_lead_valid      <= 1'b0;
        sec_fix_try       <= 4'd0;
        sec_fix_wait      <= 18'd0;
        data_rst          <= 1'b0;
        cnt_clr           <= 1'b1;

    end else if (load_abort) begin
        // 只中止当前这一次加载。
        // 【关键修复】这里绝对不能清 scan_done。扫描结果依然有效，而 sd_card_bmp 里
        // "按键切下一张"和"自动播放"的判据都要 scan_done —— 一旦在这里清掉，
        // 加载超时重试一次之后按键就永久失效（原先的 bug）。
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        write_req         <= 1'b0;
        load_sector_latched <= 32'd0;
        first_data_sec    <= 1'b0;
        o_lead_valid      <= 1'b0;
        sec_fix_try       <= 4'd0;
        sec_fix_wait      <= 18'd0;
        data_rst          <= 1'b0;
        cnt_clr           <= 1'b1;
    end else begin
        scan_found_valid <= 1'b0;
        hdr_clr          <= 1'b0;
        hdr_preload      <= 1'b0;
        sec_clr          <= 1'b0;
        data_rst         <= 1'b0;
        cnt_clr          <= 1'b0;
        len_set          <= 1'b0;

        case (state)
            ST_IDLE: begin
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    scan_done        <= 1'b0;
                    scan_found_total <= 4'd0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    hdr_retry           <= 5'd0;
                    hdr_wait            <= 18'd0;
                    // 【横向偏移根治】本次加载的"补黑条数/错位计数"从 0 开始
                    o_lead_valid        <= 1'b0;
                    first_data_sec      <= 1'b1;
                    sec_fix_try         <= 4'd0;
                    sec_fix_wait        <= 18'd0;
                    cnt_clr             <= 1'b1;   // 错位计数从 0 开始（由计数块执行）
                    // ⚠ 【已回退】上一版在这里插过一次"热身读"（ST_LOAD_WARM），
                    //   板级结果：第一遍烧录后能显示但被推向另一边（补黑补多了），
                    //   复位/重烧后按 K2 无反应（热身那条读可能一直不返回）。
                    //   已去掉热身，直接进取头；热身状态码保留但不再使用。
                    if (load_direct) begin
                        // 【按键切图·可信直载】跳过取头校验：装表里的 file_len/pixel_offset
                        //   + 直接发起写握手；数据相位照旧从这个扇区读（像素从 pixel_offset 起算）。
                        hdr_preload      <= 1'b1;
                        pre_file_len     <= direct_file_len;
                        pre_pixel_offset <= direct_pixel_offset;
                        write_req        <= 1'b1;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        state            <= ST_LOAD_HDR;
                    end
                end
            end

            // ---- 【已停用】ST_LOAD_WARM：丢弃式热身读 ----
            //   板级结果不好（复位后按 K2 无反应），已不再进入这个状态；保留代码备查。
            ST_LOAD_WARM: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;
                if (sd_sec_read_end) begin
                    sd_sec_read      <= 1'b0;
                    sd_sec_read_addr <= load_sector_latched;
                    state            <= ST_LOAD_HDR;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;

                    if (header_match) begin
                        // 【注意】此处**不做二次复读确认**：
                        //   板级实测真实 SD 扇区读本来就会偶发失败（同一扇区第一次读不出来、
                        //   重试就好），一旦要求"两次都命中"，真图也会被全部否掉，
                        //   结果图片表变空、K2/K4 全无反应。所以这里照旧立即记录，
                        //   误匹配改由"加载失败时换条目重试"来兜（sd_card_bmp 的 load_skip）。
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        // 【可信直载】同拍锁存这张图的 file_len / pixel_offset（供跳过取头时用）
                        o_scan_file_len     <= file_len;
                        o_scan_pixel_offset <= pixel_offset;
                        scan_found_total  <= scan_found_total + 4'd1;

                        if ((scan_found_total + 4'd1 >= scan_target_count) || (next_scan_sector_if_match > scan_max_sector)) begin
                            scan_done        <= 1'b1;
                            state            <= ST_IDLE;
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end
                    end else begin
                        if (scan_sector >= scan_max_sector) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_miss;
                            scan_sector      <= next_scan_sector_if_miss;
                        end
                    end
                end
            end

            // ---- 复读确认：同扇区再读一次，仍命中才记录（当前未启用）----
            ST_SCAN_VRFY: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_match) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 4'd1;

                        if ((scan_found_total + 4'd1 >= scan_target_count) || (next_scan_sector_if_match > scan_max_sector)) begin
                            scan_done        <= 1'b1;
                            state            <= ST_IDLE;
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                            state            <= ST_SCAN;
                        end
                    end else begin
                        // 两次不一致 = 误匹配：跳过这个扇区继续扫，不占用图片表
                        if (scan_sector >= scan_max_sector) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= scan_sector + 32'd1;
                            scan_sector      <= scan_sector + 32'd1;
                            state            <= ST_SCAN;
                        end
                    end
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;

                // 重试间隔：等 hdr_wait 走完再把 sd_sec_read 抬起来（给卡留缓冲时间）
                if (hdr_wait != 18'd0) begin
                    hdr_wait    <= hdr_wait - 18'd1;
                    sd_sec_read <= 1'b0;
                end else begin
                    sd_sec_read <= 1'b1;
                end

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_match) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        hdr_retry        <= 5'd0;
                        hdr_wait         <= 18'd0;
                        // 【取头读复用】这一次读是对齐的（头部校验通过了）：
                        //   它的像素部分就是图像真正的开头 ⇒ 帧首缺字量恒为 0 ⇒ 不补黑。
                        o_lead_words     <= 10'd0;
                        o_lead_valid     <= 1'b1;
                        state            <= ST_LOAD_WAIT;
                    end else if (hdr_retry != HDR_RETRY_MAX) begin
                        // 【按键可靠性】同一个扇区就地重读。
                        // 注意 sd_sec_read 先拉低一拍，让 SD 控制器的
                        // S_WAIT_READ_WRITE 重新锁存地址、重新发 CMD17。
                        hdr_retry        <= hdr_retry + 5'd1;
                        hdr_wait         <= HDR_RETRY_WAIT;
                        sd_sec_read_addr <= load_sector_latched;
                        hdr_clr          <= 1'b1;      // 由头字段所在的 always 块执行清零
                    end else begin
                        // 重试用尽：回到 IDLE。由上层的超时（sd_card_bmp 里的
                        // LOAD_TIMEOUT_CYCLES）释放 load_busy 并安排整链重试。
                        hdr_retry <= 5'd0;
                        hdr_wait  <= 18'd0;
                        state     <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    if (use_replay) begin
                        // 【必须对齐】字节计数要从 pixel_offset 起算，与 rp_cnt 同步：
                        //   否则计数从 0 开始、而数据从第 54 字节开始 ⇒ 相位错开 53 字节
                        //   （53 mod 3 = 2 ⇒ 颜色通道整体转一格 = 红蓝不对，同时帧首少 53 字节）。
                        //   板级就是这么露出来的：显示效果回到"修颜色之前那一版"。
                        //   赋值只能由计数块执行 ⇒ 抬请求标志（否则 TD 报 HDL-8007 多驱动）。
                        len_set     <= 1'b1;
                        len_set_val <= pixel_offset[9:0];
                        // 【必须 -1】预置那一拍本身不产生"字节事件"，所以起点要退一格：
                        //   否则 hdr_buf[pixel_offset] 这第一个字节既不被计数、也不被发出
                        //   ⇒ 数据流从第 55 字节开始 ⇒ **字节相位偏 1 ⇒ 颜色通道整格旋转**
                        //   （板级现象：a1 那张"天空变黄绿、树变紫红"，与修颜色之前一模一样）。
                        rp_cnt      <= pixel_offset[9:0] - 10'd1;
                        state       <= ST_LOAD_REPLAY;
                    end else begin
                        state       <= ST_LOAD_DATA;
                    end
                end
            end

            // ---- 【取头读复用】把取头那次读的像素字节重放成数据流的开头 ----
            ST_LOAD_REPLAY: begin
                state_code <= 4'd4;
                sd_sec_read <= 1'b0;
                if (rp_cnt == 10'd511 && replay_ready) begin
                    // 重放完：数据相位从**下一个扇区**继续
                    sd_sec_read_addr <= load_sector_latched + 32'd1;
                    first_data_sec   <= 1'b0;          // 第一个扇区已由取头读出，不再做错位检测
                    state            <= ST_LOAD_DATA;
                end else if(replay_ready||rp_cnt<pixel_offset[9:0])begin
                    rp_cnt <= rp_cnt + 10'd1;
                end
            end

            ST_LOAD_DATA: begin
                state_code <= 4'd4;
                // 【横向偏移根治 v2】丢弃重读之间要先放过一小段空闲（SEC_FIX_EN=1 时才用）
                if (sec_fix_wait != 18'd0) begin
                    sec_fix_wait <= sec_fix_wait - 18'd1;
                    sd_sec_read  <= 1'b0;
                end else begin
                    sd_sec_read  <= 1'b1;
                end

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    // ---- 【横向偏移根治 v2】第一个数据扇区错位 -> 丢弃重读（本轮关闭）----
                    if (first_data_sec && sec_bad && SEC_FIX_EN && (sec_fix_try != SEC_FIX_MAX)) begin
                        // 丢弃零损失：像素从第 54 字节才开始发出，而判定在前 6 字节内完成。
                        sec_fix_try  <= sec_fix_try + 4'd1;
                        sec_fix_wait <= SEC_FIX_WAIT;
                        data_rst     <= 1'b1;
                    end else begin
                        data_rst <= 1'b0;
                        if (first_data_sec) begin
                            // 【横向偏移】补黑条数 = "这次第一条数据读到底有没有错位"：
                            //   错位（内容整体前移）→ 按板级实测的 170 个字补（取最近的 4 的倍数 172）；
                            //   没错位 → 一个字都不补（否则反而把整幅图右推 172）。
                            //   有了热身，正常情况下这里应当一直报 0。
                            o_lead_words   <= sec_bad ? 10'd172 : 10'd0;
                            o_lead_valid   <= 1'b1;
                            first_data_sec <= 1'b0;
                            sec_fix_try    <= 4'd0;
                        end
                        sec_clr <= 1'b1;                // 下一扇区重新计数（由计数块执行）

                        if (FLEXIBLE_BMP) begin
                            state <= ST_LOAD_CHECK;
                        end else if (bmp_len_cnt >= file_len) begin
                            state <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                        end
                    end
                end
            end

            // Sector transfer is already complete. Separate the 32-bit EOF
            // comparison from the next sector's address/mode multiplexers.
            // Keep row position and RGB byte phase across these idle clocks.
            ST_LOAD_CHECK: begin
                state_code <= 4'd4;sd_sec_read <= 1'b0;
                state <= (bmp_len_cnt >= file_len) ? ST_IDLE : ST_LOAD_NEXT;
            end
            ST_LOAD_NEXT: begin
                state_code <= 4'd4;sd_sec_read <= 1'b0;
                sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                state <= ST_LOAD_DATA;
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule

