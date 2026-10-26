
module sd_card_bmp #(
    parameter EXTERNAL_CONTROL = 0,
    parameter FLEXIBLE_BMP = 0,
    parameter WAIT_DISPLAY_ACK = 1'b0,
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [3:0]   SCAN_TARGET_COUNT = 4'd8,
    // 加载兜底超时。必须留足：实测扫描结束后紧接的那一次扇区读可能取头失败，
    // 要靠这个超时释放 load_busy 再重试，而重试间隔太短（试过 10ms）会让
    // 下一次扇区读直接挂住，形成"挂住→超时→再挂住"的黑屏死循环。
    // 1 秒是这块卡上实测可用的值。仿真里可以调小以便快速跑完。
    parameter [31:0]  LOAD_TIMEOUT_CYCLES = 32'd100_000_000,
    // 【第三轮】失败自动恢复：SD 控制器软复位 + 隔多久自动重试一次 + 最多几次
    //   0.25s @100MHz。原来 1.2s 是为了"等卡缓过来"，但真正的卡死点在
    //   sd_card_cmd 的 S_READ_WAIT 死等（已加超时）—— 现在整条恢复链是通的，
    //   重试间隔没必要那么长，缩短到 0.25s 让按键反馈快得多。
    parameter [31:0]  RETRY_WAIT_CYCLES   = 32'd25_000_000,   // 0.25s @100MHz
    parameter [2:0]   RETRY_MAX           = 3'd4
)(    output[15:0] source_width,source_height,
    output source_top_down,
    input                       stream_ready,
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_auto,
    input                       next_press_i,auto_enable_i,settings_active_i,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output [2:0]                osd_buffer0_image,
    output [2:0]                osd_buffer1_image,
    output [23:0] osd_buffer0_size,osd_buffer1_size,
    output                      osd_auto_mode,
    output reg                  display_valid,
    output      [3:0]           state_code,
    // 诊断输出：本次上电扫描到的 BMP 张数。
    // 只有 ≥2 张时，按 K2 才能换到"下一张"、K4 自动轮播才有意义
    // （K4 的条件就是 img_found_count > 1）。所以这个数是排查
    // "按 K2 画面不变 / K4 没反应"的第一手依据。
    output      [3:0]           img_total,
    // 【第三轮诊断】最近一次取头读到的头两字节 + 当前这次加载的目标扇区
    output      [7:0]           dbg_hdr0,
    output      [7:0]           dbg_hdr1,
    output      [31:0]          dbg_load_sector,
    // 【横向偏移根治】源端实测的"本帧帧首补黑条数"（原样透传给写侧）
    output      [9:0]           o_lead_words,
    output                      o_lead_valid,
    // 【横向偏移根治 v2 诊断】第一个数据扇区"抓错令牌、丢弃重读"的次数
    output      [3:0]           o_sec_fix_cnt,
    // 【诊断】把这两个状态信号露出来给数码管用（判断"按 K2 没反应"到底卡在哪一步）
    output                      o_scan_done,
    output                      o_sd_init_done,
    input                       write_finish_toggle,
    input [1:0]                 display_buf_ack,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

// Register the scaler backpressure before sector replay/address control.
// The scaler stops at8/16 queue entries, leaving ample room for this extra
// one-clock return latency and the existing registered byte/pixel pipeline.
reg stream_ready_q;
always @(posedge clk or posedge rst)
 if(rst)stream_ready_q<=0;else stream_ready_q<=stream_ready;
wire key_next_press;
wire legacy_next_press,legacy_auto_press;
wire paused=EXTERNAL_CONTROL&&settings_active_i;
wire auto_effective=EXTERNAL_CONTROL?auto_enable_i:auto_play_en;
assign key_next_press=EXTERNAL_CONTROL?next_press_i:legacy_next_press;
wire key_auto_press=EXTERNAL_CONTROL?1'b0:legacy_auto_press;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire [3:0]       state_code_i;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             bmp_ready;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [3:0]       scan_found_total;
// 【按键切图·可信直载】扫描命中那一刻解析出的 file_len / pixel_offset
wire [31:0]      scan_file_len_w;
wire [31:0]      scan_pixel_offset_w;
wire             scan_timeout_w;        // 【扫描看门狗】bmp_read 报"这次扫描读超时"

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
reg              auto_play_en;
reg [31:0]       auto_cnt;
reg [3:0]        img_found_count;
reg [2:0]        img_idx;              // 当前真正显示中的图片编号
reg [2:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [16:0]       img_sector0;
reg [16:0]       img_sector1;
reg [16:0]       img_sector2;
reg [16:0]       img_sector3;
reg [16:0]       img_sector4;
reg [16:0]       img_sector5;
reg [16:0]       img_sector6;
reg [16:0]       img_sector7;
// 【按键切图·可信直载】扫描时逐张记下 file_len / pixel_offset（供"跳过取头"的兜底用）
wire[31:0]scan_width_w,scan_height_w;
reg[11:0]img_width[0:7],img_height[0:7];reg img_topdown[0:7];
reg[11:0]direct_width_r,direct_height_r;reg direct_topdown_r;
wire[31:0]scan_abs_height=scan_height_w[31]?(~scan_height_w+32'd1):scan_height_w;
wire signed[12:0]signed_direct_height=direct_topdown_r?-$signed({1'b0,direct_height_r}):$signed({1'b0,direct_height_r});
// Valid header bounds imply file_len<=12587519, below2^24.
reg [23:0]       img_flen [0:7];
reg [8:0]        img_poff [0:7];
reg              load_direct_r;      // 1 = 下一次加载直接用表里的信息（不再做取头校验）
reg [31:0]       direct_flen_r;
reg [31:0]       direct_poff_r;
reg              next_req_pending;
reg              load_busy;
reg [31:0]       load_timeout_cnt;

reg              load_abort;

// ---- 【第二轮板级修复】加载失败后的自动恢复 ----
//   板级现象：第一张图正常显示后，再按 K2/K4 毫无反应。
//   原因方向：后续的取头（CMD17 读第一个扇区）失败 —— 要么卡在
//   sd_card_sec_read_write 的 S_CMD17 无限重试里，要么读回来的头不对。
//   而原来只有"1 秒超时 + 等用户再按一次键"这种被动恢复，用户按了也没反应。
//   这里改成主动恢复：
//     ① 超时时给 SD 控制器一个 sd_reinit 脉冲（重走 CMD0…CMD16，但不复位上层）；
//     ② 隔 1.2 秒自动重新发起这次加载（最多 4 次），用户不用反复按键；
//     ③ 任何一次成功提交都把重试计数清零。
reg [2:0]        retry_cnt;
reg [31:0]       retry_wait;
reg [4:0]        reinit_cnt;
reg              sd_reinit_r;
// 【第三轮加固】取头失败时"换下一条目再试"——板级实测图片表里可能混进假条目
//   （卡上已删除图片的物理残留），失败后一直重试同一条目永远切不过去。
//   这里每次失败把 load_skip +1，最多跳 3 次；成功提交或用户按键时清零。
reg [2:0]        load_skip;

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
reg              write_done_seen;
reg              source_active_seen;
reg              write_phase_started;
reg [1:0]        display_ack_s0, display_ack_s1;
wire display_released = !WAIT_DISPLAY_ACK || !display_valid ||
                        (display_ack_s1 == disp_buf_idx);

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire auto_tick;
wire [2:0] next_from_current;

assign write_en   = bmp_data_wr_en;assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
assign o_scan_done    = scan_done;
assign o_sd_init_done = sd_init_done;
assign auto_tick  = (auto_cnt == (CLK_FREQ_HZ - 1));
assign next_from_current = next_index_limited(img_idx, img_found_count);

// 【KEY2 手动加载索引】第一次按下 KEY2 取第 0 张，之后按 next_from_current 递进。
// 不能直接用 next_from_current：首次加载时 img_idx 还是 0，
// 而 next_index_limited 在 img_found_count==2 下把 0 映射成 1，
// 结果第一次按下就跳过第 0 张（直接显示第 2 张）。
wire [2:0] manual_idx = first_image_committed ? next_from_current : 3'd0;
// 【按键切图修复】实际加载用的索引 = 目标索引 + load_skip，但**必须仍然落在真实图片表内**。
//   原实现是 2 位加法：load_skip 累加到 3 时会回绕（例：目标第 2 张 + 3 = 第 1 张），
//   于是"加载失败 → 换条目重试"反而又回到已经显示过的那张图上 —— 板级现象正是
//   "按 K2 之后画面还是原来那张"。现在折回 [0, img_found_count-1]，
//   保证每次重试都打在真实存在的图片上（也绝不会指到空条目/扇区 0）。
wire [3:0] manual_raw = {1'b0, manual_idx} + {1'b0, load_skip};
wire [3:0] auto_raw   = {1'b0, next_from_current} + {1'b0, load_skip};
// Retries deliberately keep the same image; load_skip has only zero/self assignments.
wire [2:0] manual_idx_eff = manual_idx;
wire [2:0] auto_idx_eff   = next_from_current;
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
assign state_code = state_code_i;
assign img_total  = img_found_count;      // 诊断：扫描到的图片张数
assign dbg_load_sector = load_sector;     // 诊断：本次加载的目标扇区（十六进制看低 3 位）

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(legacy_next_press)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(legacy_auto_press)
);

function [2:0] next_index_limited;
 input[2:0]cur;input[3:0]count;
 begin case(count)
 0,1:next_index_limited=0;
 2:next_index_limited=cur==1?3'd0:cur+3'd1;
 3:next_index_limited=cur==2?3'd0:cur+3'd1;
 4:next_index_limited=cur==3?3'd0:cur+3'd1;
 5:next_index_limited=cur==4?3'd0:cur+3'd1;
 6:next_index_limited=cur==5?3'd0:cur+3'd1;
 7:next_index_limited=cur==6?3'd0:cur+3'd1;
 default:next_index_limited=cur+3'd1;
 endcase end
endfunction

function [31:0] sector_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: sector_lut = img_sector0;
            3'd1: sector_lut = img_sector1;
            3'd2: sector_lut = img_sector2;
            3'd3: sector_lut = img_sector3;
            3'd4: sector_lut = img_sector4;
            3'd5: sector_lut = img_sector5;
            3'd6: sector_lut = img_sector6;
            3'd7: sector_lut = img_sector7;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

// 【按键切图修复】把"目标索引 + load_skip"折回真实图片表范围 [0, count-1]。
//   调用前已保证 load_skip <= count-1（见下面 load_skip 的累加条件），
//   所以 raw <= 2*count-2，一次减法就够。
function [2:0] idx_in_table;
 input [3:0] raw,count;
 begin if(count<=1)idx_in_table=0;else if(raw>=count)idx_in_table=raw-count;else idx_in_table=raw[2:0];end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        auto_play_en          <= 1'b0;
        auto_cnt              <= 32'd0;
        img_found_count       <= 4'd0;
        img_idx               <= 3'd0;
        load_idx              <= 3'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        img_sector4 <= 17'd0;
        img_sector5 <= 17'd0;
        img_sector6 <= 17'd0;
        img_sector7 <= 17'd0;
        load_direct_r         <= 1'b0;
        direct_width_r<=0;direct_height_r<=0;direct_topdown_r<=0;
        direct_flen_r         <= 32'd0;
        direct_poff_r         <= 32'd0;
        next_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        load_timeout_cnt      <= 32'd0;
        load_abort            <= 1'b0;
        source_done_seen      <= 1'b0;
        write_done_seen       <= 1'b0;
        source_active_seen    <= 1'b0;
        write_phase_started   <= 1'b0;
        display_ack_s0        <= 2'd0;
        display_ack_s1        <= 2'd0;
        load_skip             <= 3'd0;
        display_valid         <= 1'b0;
        retry_cnt             <= 3'd0;
        retry_wait            <= 32'd0;
        reinit_cnt            <= 5'd0;
        sd_reinit_r           <= 1'b0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        display_ack_s0 <= display_buf_ack;
        display_ack_s1 <= display_ack_s0;
        if (!load_busy) begin
            source_active_seen <= 1'b0;
            write_phase_started <= 1'b0;
        end else begin
            if (!bmp_ready) source_active_seen <= 1'b1;
            if (write_req && write_req_ack) write_phase_started <= 1'b1;
        end
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;

        // ---- 【扫描看门狗】扫描阶段某次扇区读超时 ⇒ 重启 SD 控制器 + 重新扫描 ----
        //   不加这一条的话，卡被上一次中止的读留在半途时，扫描会永远等不到 read_end，
        //   scan_done 永远为 0 ⇒ 按 K2 永远没反应（板级实测：复位后卡在 state=2、找到 0 张）。
        if (scan_timeout_w) begin
            reinit_cnt       <= 5'd31;      // 重走 CMD0…CMD16 + 补 88 个唤醒时钟
            scan_start_pulse <= 1'b1;       // 重新从头扫描
            // 注意 scan_done 是 bmp_read 的输出（wire），这里不能赋值 ——
            //   bmp_read 收到 scan_start 自己会把 scan_done 清 0 并重扫。
            scan_kicked      <= 1'b1;
            img_found_count  <= 4'd0;
            img_idx          <= 3'd0;
            load_idx         <= 3'd0;
            pending_buf_idx  <= 2'd0;
            display_valid    <= 1'b0;
            load_busy        <= 1'b0;
            next_req_pending <= 1'b0;
        end

        // ---- 失败恢复：SD 控制器软复位脉冲 + 自动重试倒计时 ----
        if (reinit_cnt != 5'd0) begin
            reinit_cnt  <= reinit_cnt - 5'd1;
            sd_reinit_r <= 1'b1;
        end else begin
            sd_reinit_r <= 1'b0;
        end
        if (retry_wait != 32'd0) begin
            retry_wait <= retry_wait - 32'd1;
            if (retry_wait == 32'd1) next_req_pending <= 1'b1;   // 到点自动重发这次加载
        end

        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 4'd0;
            img_idx               <= 3'd0;
            load_idx              <= 3'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
        img_sector4 <= 17'd0;
        img_sector5 <= 17'd0;
        img_sector6 <= 17'd0;
        img_sector7 <= 17'd0;
            next_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            load_timeout_cnt      <= 32'd0;
            load_abort            <= 1'b0;
            source_done_seen      <= 1'b0;
            write_done_seen       <= 1'b0;
            display_valid         <= 1'b0;
        end else begin
            // 扫描阶段缓存前 4 张图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    4'd4: img_sector4 <= scan_found_sector;
                    4'd5: img_sector5 <= scan_found_sector;
                    4'd6: img_sector6 <= scan_found_sector;
                    4'd7: img_sector7 <= scan_found_sector;
                    default: ;
                endcase
                // 【按键切图·可信直载】同时记下这张图的 file_len / pixel_offset
                if (img_found_count < 4'd8) begin
                    img_width[img_found_count]<=scan_width_w[11:0];img_height[img_found_count]<=scan_abs_height[11:0];img_topdown[img_found_count]<=scan_height_w[31];
                    img_flen[img_found_count] <= scan_file_len_w;
                    img_poff[img_found_count] <= scan_pixel_offset_w;
                end

                if (img_found_count < 4'd8)
                    img_found_count <= img_found_count + 4'd1;
            end

            // 记住 bmp_read 已经把源图送完 FIFO，但还不能切显示，得等整帧写完
            if (load_busy && source_active_seen && bmp_ready)
                source_done_seen <= 1'b1;

            // 记住写帧完成脉冲，避免“先写完后源结束”导致脉冲丢失而卡死
            if (load_busy && write_phase_started && write_finish_pulse)
                write_done_seen <= 1'b1;

            // 只有“源图送完 + 整帧写完”都满足，才提交新图并切换显示缓冲区
            if (load_busy && source_done_seen && write_done_seen) begin
                load_busy             <= 1'b0;
                load_timeout_cnt      <= 32'd0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                disp_buf_idx          <= pending_buf_idx;
                img_idx               <= load_idx;
                display_valid         <= 1'b1;
                first_image_committed <= 1'b1;
                retry_cnt             <= 3'd0;          // 成功即清零重试计数
                retry_wait            <= 32'd0;
                load_skip             <= 3'd0;
                load_direct_r         <= 1'b0;          // 成功即回到"正常校验"模式
            end else if (load_busy) begin
                if (load_timeout_cnt > LOAD_TIMEOUT_CYCLES) begin
                    // 超时（例如读到坏图或截断的文件导致死锁），强制释放 busy 以恢复按键响应
                    load_busy             <= 1'b0;
                    load_timeout_cnt      <= 32'd0;
                    source_done_seen      <= 1'b0;
                    write_done_seen       <= 1'b0;
                    load_abort            <= 1'b1;
                    // 【按键切图·可信直载】取头校验失败 ⇒ 下一次重试直接按表里的信息加载
                    //   （扫描已经校验过那个扇区；板级实测该扇区的取头是确定性读错的，重试无用）
                    load_direct_r         <= 1'b1;
                    // 【第二轮】主动恢复：**重启 SD 控制器**（重走 CMD0…CMD16 + 补 88 个唤醒时钟）
                    //   + 1.2 秒后自动重试同一张图。
                    //   ⚠ 21:09 那版试过把它去掉，板级反而更糟（后面按键全不动、复位卡在 000002
                    //     的"扫描永远不结束"）—— 因为读卡被中止时卡还停在半途，需要这套恢复
                    //     把它拉回来。所以这里**恢复**它。
                    if (retry_cnt < RETRY_MAX) begin
                        retry_cnt  <= retry_cnt + 3'd1;
                        retry_wait <= RETRY_WAIT_CYCLES;
                        reinit_cnt <= 5'd31;
                        // 【按键切图修复】这里**不再"换条目"**：重试仍然打同一张目标图。
                        //   板级实测：切第二张时读头会失败好几次、重试就能成功；而原来
                        //   "失败就换下一条目 + load_skip 累加"会把目标从第 2 张挪到第 3 条
                        //   （空条目/扇区 0）、2 位宽再回绕到第 1 张 —— 用户看到的就是
                        //   "按 K2 之后还是原来那张图"。现在的卡已用 PC 裸扇区扫描确认
                        //   只有两个合法图片头（8256 / 10112），所以"换条目跳假图"没有意义。
                        //   （若以后真遇到卡里混入假条目，把下面这行自增放回来即可。）
                        load_skip <= load_skip;
                    end
                end else begin
                    load_timeout_cnt <= load_timeout_cnt + 32'd1;
                end
            end else begin
                load_timeout_cnt <= 32'd0;
            end

            // 上电后自动发起一次“扫描前 4 张 BMP”
            if (!scan_kicked && bmp_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                img_found_count       <= 4'd0;
                img_idx               <= 3'd0;
                load_idx              <= 3'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                next_req_pending      <= 1'b0;
                display_valid         <= 1'b0;
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
            end else begin
                // 忙的时候也只记 1 次“下一张”请求，不会累积成连跳两张
                if (key_next_press && !paused && scan_done && (img_found_count > 3'd0)) begin
                    next_req_pending <= 1'b1;
                    retry_cnt        <= 3'd0;      // 用户手动按键 => 重新给满自动重试次数
                    load_skip        <= 3'd0;      // 并从"目标图的原始条目"重新开始找
                    load_direct_r    <= 1'b0;      // 用户按键 => 先走正常取头校验
                end

                // 自动播放开/关
                if (key_auto_press && scan_done && (img_found_count > 3'd1)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt     <= 32'd0;
                end

                if(EXTERNAL_CONTROL && auto_effective && !paused && scan_done && !first_image_committed && !load_busy && img_found_count!=0)next_req_pending<=1;

                // 自动播放 1s 计数：只有当前没有写图任务时才计时
                if (scan_done && auto_effective && !paused && display_valid && !load_busy && first_image_committed && (img_found_count > 3'd1)) begin
                    if (auto_tick)
                        auto_cnt <= 32'd0;
                    else
                        auto_cnt <= auto_cnt + 32'd1;
                end else begin
                    auto_cnt <= 32'd0;
                end

                // 注意：这三条加载分支都要求 scan_done。
                // bmp_read 在 load_abort 时绝不能再清 scan_done（已在那边修掉），
                // 否则加载超时重试一次之后按键切图与自动播放会永久失效。
                //
                // 【重要】手动"下一张"必须排在首图分支之前。
                // 首图分支的条件里 first_image_committed=0 会一直成立，若它排在前面，
                // 只要首图加载不上，用户按键就永远被它饿死 —— 这是"按键切不了图"的直接原因。
                // 按键请求（next_req_pending）是用户显式意图，优先级应当最高。
                if (scan_done && !paused && bmp_ready && !load_busy && display_released && next_req_pending && (img_found_count != 3'd0)) begin
                    load_idx         <= manual_idx_eff;
                    load_sector      <= sector_lut(manual_idx_eff);
                    // 【按键切图·可信直载】把这张图的 file_len/pixel_offset 也锁存下来
                    direct_width_r<=img_width[manual_idx_eff];direct_height_r<=img_height[manual_idx_eff];direct_topdown_r<=img_topdown[manual_idx_eff];
                    direct_flen_r    <= img_flen[manual_idx_eff];
                    direct_poff_r    <= img_poff[manual_idx_eff];
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                    // 【第三轮治本】发起加载前先给 SD 控制器一个软复位脉冲（重走初始化 +
                    //   补 88 个唤醒时钟）：板级实测"每次加载的第一次扇区读会失败、重试就好"，
                    //   属于长时间空闲后卡/控制器状态不对。21:09 那版去掉过它，板级变差
                    //   （扫描都可能永远不结束）⇒ 这里恢复。
                    reinit_cnt       <= 5'd31;
                end
                // 【本条已按需求移除】原"首图上电自动加载到 buffer0"分支。
                // 需求：KEY2 是唯一的加载入口，上电后画面保持黑屏（display_valid=0），
                // 直到用户第一次按下 KEY2 才开始读 SD 卡。
                // 首图必须落在 buffer0，因此下面手动分支用 manual_idx 保证
                // "第一次按下取第 0 张"，而不是 next_from_current 从 0 跳到 1。
                // 自动播放下一张：写到"非当前显示"的另一块 buffer
                else if (scan_done && !paused && bmp_ready && display_valid && display_released && !load_busy && auto_effective && auto_tick && (img_found_count > 3'd1)) begin
                    load_idx         <= auto_idx_eff;
                    load_sector      <= sector_lut(auto_idx_eff);
                    direct_width_r<=img_width[auto_idx_eff];direct_height_r<=img_height[auto_idx_eff];direct_topdown_r<=img_topdown[auto_idx_eff];
                    direct_flen_r    <= img_flen[auto_idx_eff];
                    direct_poff_r    <= img_poff[auto_idx_eff];
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    auto_cnt         <= 32'd0;
                    reinit_cnt       <= 5'd31;   // 同上：自动轮播发起加载前也先软复位 SD 控制器
                end
            end
        end
    end
end


// Subtitle-only metadata: tag inactive buffer before its pixels are loaded.
reg[2:0]osd_tag0,osd_tag1;
reg[23:0]osd_size0,osd_size1;
assign osd_buffer0_size=osd_size0;assign osd_buffer1_size=osd_size1;
// Frame payload; consumer is gated by display_valid. Updated only when the
// inactive frame begins loading, before the later full-frame commit/ACK.
always @(posedge clk)if(load_busy&&write_req&&write_req_ack)begin
 if(pending_buf_idx[0])osd_size1<={direct_width_r,direct_height_r};
 else osd_size0<={direct_width_r,direct_height_r};
end

assign osd_buffer0_image=osd_tag0;
assign osd_buffer1_image=osd_tag1;
assign osd_auto_mode=auto_effective;
always @(posedge clk or posedge rst)begin
 if(rst)begin osd_tag0<=0;osd_tag1<=0;end
 else if(load_busy&&write_req)begin
  if(pending_buf_idx[0])osd_tag1<=load_idx;else osd_tag0<=load_idx;
 end
end

bmp_read #(.FLEXIBLE_BMP(FLEXIBLE_BMP)) bmp_read_m0(
    .pixel_ready(stream_ready_q),.direct_width({20'd0,direct_width_r}),.direct_height({{19{signed_direct_height[12]}},signed_direct_height}),
    .source_width(source_width),.source_height(source_height),.source_top_down(source_top_down),
    .o_scan_width(scan_width_w),.o_scan_height(scan_height_w),
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (load_sector),
    // 【按键切图·可信直载】取头校验失败后的兜底通道
    .load_direct            (load_direct_r),
    .direct_file_len        (direct_flen_r),
    .direct_pixel_offset    (direct_poff_r),
    .o_scan_file_len        (scan_file_len_w),
    .o_scan_pixel_offset    (scan_pixel_offset_w),
    .o_scan_timeout         (scan_timeout_w),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code_i),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data),
    .o_header_0             (dbg_hdr0),
    .o_header_1             (dbg_hdr1),
    .o_lead_words           (o_lead_words),
    .o_lead_valid           (o_lead_valid),
    .o_sec_fix_cnt          (o_sec_fix_cnt)
);

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .sd_reinit              (sd_reinit_r),
    .stream_ready           (stream_ready_q || (state_code_i != 4'd4)),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule

