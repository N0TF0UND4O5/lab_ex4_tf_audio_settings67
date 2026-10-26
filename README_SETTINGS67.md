# settings67：底部 HDMI 设置、独立字幕与 TFT 互斥

本工程从用户认可的 settings61 独立复制。settings61 原工程与位流不改。
TFT66 用户已报告卡死，不作为本版基线。没有执行下载或写 Flash。

## 使用

- SW1 向上（C8=1）：HDMI 底部显示四列、三行设置，TFT 背光关闭，TFT 总线停在空闲。
- SW1 向下（C8=0）：HDMI 设置隐藏，TFT 按 settings61 原初始化流程恢复；设置值不丢失。
- SW1 两级同步、20ms 消抖，在 HDMI 帧消隐边界提交切换。
- 设置区 x16..623、y392..463，608×72，12px 白字、当前项蓝色高亮、50%背景混合。
- 字幕独立位于设置上方 x16..623、y356..385；16px 文本“你好请排队   安路赛道赛题一”，中间留3个16px空格。
- “字幕显示”仅控制这一行；“字幕滑动”控制该行滚动/静止。隐藏 HDMI 设置不会隐藏或停止字幕。
- 静止文本居中；滚动每视频帧移动1px，从右向左，完整移出后循环。应急状态沿用原暂停字幕滚动行为。
- 原导航键选项顺序不变：第一列从上到下，再进入右侧列。原音频、图片、网络告警和上方分辨率标注保留。

## 实现与资源

菜单的TFT24px字形与HDMI12px字形共用一个字库/渲染器；HDMI采用2×2字形像素OR合并，保留细笔画。
TFT总线时序与状态机沿用settings61，没有采用tft64/65/66的重写方案。
BMP512字节头缓存改为同步块RAM，并预取下一回放地址，保持原模块逐拍数据/控制行为。
字幕新字形放进原1024×16字库未新增字幕ROM容量，初始化文件均指向本工程副本。
资源与最终时序以doc/release_manifest67.json和src/td_project/settings67_release_build.log为准。

## 验证与构建

- tb_bmp67.v：新旧模块逐拍比较；直载/头回放，持续接收/间歇反压，7×3、8×3、320×240，直载另含480×800。四组均通过。
- tb_renderer67.v：524160像素，TFT原尺寸逐像素等价，41种合法设置值，三页12px2×2合并对照通过。
- tb_tft61_equivalence67.v：2151691拍、153716次写；初始化及两页菜单所有TFT引脚/数据/ready逐拍等价。
- tb_router67.v：1555347拍，整条字幕+设置7拍视频链；五帧覆盖SW1消抖、帧边界切换、两屏互斥、87552个面板像素、选项/背景/字形、字幕关闭/静止/滚动/应急暂停。
- doc/diagnostics/settings67_hdmi_preview.png 是已通过精确像素对照的RTL仿真画面，不是硬件实拍。

TD5.6.5_SP3；src/td_project/build67.tcl：seed3、place opt_timing off、route effort/opt_timing high。
构建前生成字幕资源：python doc/diagnostics/generate_subtitle67_font.py。
在src/td_project运行TD命令行，参数为build67.tcl。
check_timing.py保留settings61的严格业务时序门槛：业务setup/hold必须为0，只允许继承的最多3条音频复位recovery。
封装SDRAM外部IO告警另列，不可把时钟域门槛通过说成全STA零告警。

## 当前交付

最终位流：src/td_project/settings67.bit，713441字节，SHA256 `ef9fc733c259cb066e2a0bfc2cc2f68878a7a7639a39d05f12e4ddb350f8c490`。
资源：{'MSLICE': 4624, 'LSLICE': 4624, 'PAD': 124, 'BRAM': 60, 'DSP': 21}，相对settings61：{'MSLICE': -53, 'LSLICE': -53, 'PAD': 1, 'BRAM': 1, 'DSP': 0}。
业务时钟setup/hold为0，保留原3条音频复位recovery及SDRAM外部IO告警。未下载，待用户自行上板验证。
本版不宣称修复TFT原有花屏/白屏，TFT开启状态仍需实测。
