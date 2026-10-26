# repair41: TD does not infer these output periods from the root declaration.
# Verified in routed report: 20/10/8/8(180deg)/40/8 ns.
# One settings51 status CDC exception below; all intra-domain paths remain checked.
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
create_generated_clock -name sd_card_clk -source [get_ports {clk}] -master_clock clk -multiply_by 2 [get_nets {sd_card_clk}]
create_generated_clock -name ext_mem_clk -source [get_ports {clk}] -master_clock clk -multiply_by 2.5 [get_nets {ext_mem_clk}]
create_generated_clock -name ext_mem_clk_sft -source [get_ports {clk}] -master_clock clk -multiply_by 2.5 -invert [get_nets {ext_mem_clk_sft}]
create_generated_clock -name video_clk -source [get_ports {clk}] -master_clock clk -multiply_by 0.5 [get_nets {video_clk}]
create_generated_clock -name hdmi_5x_clk -source [get_ports {clk}] -master_clock clk -multiply_by 2.5 [get_nets {hdmi_5x_clk}]

# Audio PLL VCO=750MHz, C2 divide=61 (12.295081967MHz).
create_generated_clock -name audio_mclk -source [get_ports {clk}] -master_clock clk -multiply_by 0.2459016393442623 [get_nets {audio_mclk}]

# settings51: settings_mode is the only SD->MCLK signal, a human-speed level.
# It enters music_pause_sync[0] then [1]; neither drives I2S clocks.
# Exempt asynchronous launch->first synchronizer sampling, preserving all
# MCLK->MCLK checks including sync[0]->sync[1] and melody data paths.
set_false_path -from [get_clocks {sd_card_clk}] -to [get_clocks {audio_mclk}]

# player52: the only audio_mclk -> video_clk data paths are BCLK/LRCK/DOUT
# into I2S_receiver's three-stage sampling chains. Both PLLs run continuously,
# but their noninteger ratio cannot be treated as a synchronous transfer.
# Keep all video_clk -> video_clk synchronizer stages, PCM, DFT and ACR checked.
set_false_path -from [get_clocks {audio_mclk}] -to [get_clocks {video_clk}]

# player52: video_clk -> ext_mem_clk consists only of line_tog_i and
# frame_tog_i, each sampled by line_tog_s/frame_tog_s (three registers).
# Pixel/line coordinates address the VIDEO port of the dual-port row RAM;
# they are not memory-clock input data. Exempt only the asynchronous launch
# paths. Every ext_mem_clk -> ext_mem_clk stage and SDRAM datapath stays checked.
set_false_path -from [get_clocks {video_clk}] -to [get_clocks {ext_mem_clk}]

# player52: memory -> SD/writer crosses through FIFO Gray-pointer synchronizers,
# wr_clear_sync (two stages), and the completion/display-ack sampling chains.
# The FIFO payload uses dual-clock RAM; no synchronous payload is sent on this
# clock pair. Exempt launch->first sampling, retaining SD->SD stages and all
# writer/scaler arithmetic. The SD->memory direction remains timing-checked.
set_false_path -from [get_clocks {ext_mem_clk}] -to [get_clocks {sd_card_clk}]

# Independent PHY RX125MHz domain. Held command/request/ack mailbox only.
create_clock -name emergency_rx_clk -period 8 -waveform {0 4} [get_ports {phy_rgmii_rx_clk}]
set_false_path -from [get_clocks {emergency_rx_clk}] -to [get_clocks {video_clk}]
set_false_path -from [get_clocks {video_clk}] -to [get_clocks {emergency_rx_clk}]
# Frozen music and emergency pause are slow levels into a two-stage MCLK chain.
set_false_path -from [get_clocks {video_clk}] -to [get_clocks {audio_mclk}]

# Only human-speed effect bits go through this pair into effect_sync0[1:0]
# then effect_sync1. Hold all other SD->memory FIFO/address/data paths checked.
set_false_path -from [get_clocks {sd_card_clk}] -through [get_nets {settings_config[1] settings_config[2]}] -to [get_clocks {ext_mem_clk}]
