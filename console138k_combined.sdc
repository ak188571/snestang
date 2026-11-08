# Console 138K uses the GW5AST-138B PLL, unlike the 4:1 Primer25K profile.
# fclk = 50 * 40 / 31 = 64.516129 MHz; mclk = 50 * 40 / 93.
# Describe those existing outputs without changing PLL settings.
create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {sys_clk}]
create_clock -name fclk -period 15.5 -waveform {0 7.75} [get_nets {fclk}]
create_generated_clock -name mclk -source [get_nets {fclk}] -divide_by 3 [get_nets {mclk}]

# HDMI outputs: 27 * 55 / 4 = 371.25 MHz and 27 * 55 / 20 = 74.25 MHz.
create_clock -name hclk5 -period 2.693602694 -waveform {0 1.346801347} [get_nets {hclk5}]
create_generated_clock -name hclk -source [get_nets {hclk5}] -master_clock hclk5 -divide_by 5 [get_nets {hclk}]

# Preserve the existing SDRAM transfer windows.
set_multicycle_path 3 -setup -end -from [get_clocks {mclk}] -to [get_clocks {fclk}]
set_multicycle_path 2 -hold -end -from [get_clocks {mclk}] -to [get_clocks {fclk}]
set_multicycle_path 1 -setup -end -from [get_nets {vram?_req}] -to [get_clocks {fclk}]
set_multicycle_path 3 -setup -start -from [get_clocks {fclk}] -to [get_clocks {mclk}]
set_multicycle_path 2 -hold -start -from [get_clocks {fclk}] -to [get_clocks {mclk}]

# Independent 12 MHz USB PLL. Only the implemented mailbox crossings below are excepted.
create_clock -name clk12 -period 83.333333333 -waveform {0 41.6666666665} [get_nets {clk12}]
# USB clock is derived from the 50 MHz PLL by Gowin auto-clock inference.
# Acknowledged mailbox: src_hold is held through destination capture and returned acknowledgement.
set_false_path -to [get_regs {
    joy_usb1_cdc/toggle_sync_0_s0
    joy_usb1_cdc/ack_sync_0_s0
    joy_usb1_cdc/dst_data_0_s0
    joy_usb1_cdc/dst_data_1_s0
    joy_usb1_cdc/dst_data_2_s0
    joy_usb1_cdc/dst_data_3_s0
    joy_usb1_cdc/dst_data_4_s0
    joy_usb1_cdc/dst_data_5_s0
    joy_usb1_cdc/dst_data_6_s0
    joy_usb1_cdc/dst_data_7_s0
    joy_usb1_cdc/dst_data_8_s0
    joy_usb1_cdc/dst_data_9_s0
    joy_usb1_cdc/dst_data_10_s0
    joy_usb1_cdc/dst_data_11_s0
    joy_usb2_cdc/toggle_sync_0_s0
    joy_usb2_cdc/ack_sync_0_s0
    joy_usb2_cdc/dst_data_0_s0
    joy_usb2_cdc/dst_data_1_s0
    joy_usb2_cdc/dst_data_2_s0
    joy_usb2_cdc/dst_data_3_s0
    joy_usb2_cdc/dst_data_4_s0
    joy_usb2_cdc/dst_data_5_s0
    joy_usb2_cdc/dst_data_6_s0
    joy_usb2_cdc/dst_data_7_s0
    joy_usb2_cdc/dst_data_8_s0
    joy_usb2_cdc/dst_data_9_s0
    joy_usb2_cdc/dst_data_10_s0
    joy_usb2_cdc/dst_data_11_s0
}]

# FS asynchronous pin capture and acknowledged FS->12 MHz mailboxes.
set_false_path -to [get_regs {
 usb_hid_host/owner_sync_0_s0
 usb_hid_host/fs/dp_meta_s0
 usb_hid_host/fs/dm_meta_s0
 usb_hid_host/fs/phy/dp_meta_s0
 usb_hid_host/fs/phy/dm_meta_s0
 usb_hid_host/fs_to_ls/toggle_sync_0_s0
 usb_hid_host/fs_to_ls/ack_sync_0_s0
 usb_hid_host/fs_to_ls/dst_data_0_s0
 usb_hid_host/fs_to_ls/dst_data_1_s0
 usb_hid_host/fs_to_ls/dst_data_2_s0
 usb_hid_host/fs_to_ls/dst_data_3_s0
 usb_hid_host/fs_to_ls/dst_data_4_s0
 usb_hid_host/fs_to_ls/dst_data_5_s0
 usb_hid_host/fs_to_ls/dst_data_6_s0
 usb_hid_host/fs_to_ls/dst_data_7_s0
 usb_hid_host/fs_to_ls/dst_data_8_s0
 usb_hid_host/fs_to_ls/dst_data_9_s0
 usb_hid_host/fs_to_ls/dst_data_10_s0
 usb_hid_host/fs_to_ls/dst_data_11_s0
 usb_hid_host/fs_to_ls/dst_data_12_s0
 usb_hid_host2/owner_sync_0_s0
 usb_hid_host2/fs/dp_meta_s0
 usb_hid_host2/fs/dm_meta_s0
 usb_hid_host2/fs/phy/dp_meta_s0
 usb_hid_host2/fs/phy/dm_meta_s0
 usb_hid_host2/fs_to_ls/toggle_sync_0_s0
 usb_hid_host2/fs_to_ls/ack_sync_0_s0
 usb_hid_host2/fs_to_ls/dst_data_0_s0
 usb_hid_host2/fs_to_ls/dst_data_1_s0
 usb_hid_host2/fs_to_ls/dst_data_2_s0
 usb_hid_host2/fs_to_ls/dst_data_3_s0
 usb_hid_host2/fs_to_ls/dst_data_4_s0
 usb_hid_host2/fs_to_ls/dst_data_5_s0
 usb_hid_host2/fs_to_ls/dst_data_6_s0
 usb_hid_host2/fs_to_ls/dst_data_7_s0
 usb_hid_host2/fs_to_ls/dst_data_8_s0
 usb_hid_host2/fs_to_ls/dst_data_9_s0
 usb_hid_host2/fs_to_ls/dst_data_10_s0
 usb_hid_host2/fs_to_ls/dst_data_11_s0
 usb_hid_host2/fs_to_ls/dst_data_12_s0
}]

set_false_path -to [get_regs {usb_hid_host/fs_to_ls/dst_data_13_s0 usb_hid_host2/fs_to_ls/dst_data_13_s0}]

# Explicit PLL output clock, following the existing clk12 output-clock policy.
create_clock -name clk96 -period 10.416666667 -waveform {0 5.2083333335} [get_nets {clk96}]

# Extra PLL output for the ROM transport; USB remains at clk96/clk12.
create_clock -name clk80 -period 12.5 -waveform {0 6.25} [get_nets {clk80}]

# ROM transport: only first synchronizer stages and held descriptor captures.
# The request is synchronized twice before capture; DISPATCH adds a destination
# cycle. The descriptor and RAM bank remain stable until the returned done.
# Do not except entire mclk/clk80 domains: ordinary intra-domain paths still time.
# usb_reset_sync asserts asynchronously and releases through two clk80 stages.
# Except only its asynchronous CLEAR pins; the stage-to-stage D path stays timed.
set_false_path -to [get_pins {
 rom_reset80_release/reset_pipe_0_s0/CLEAR
 rom_reset80_release/reset_pipe_1_s0/CLEAR
}]
set_false_path -to [get_regs {
 rom_link/phy/rx_sync_0_s0
 rom_link/engine/done_sync_0_s0
 rom_link/engine/ok_sync0_s0
 rom_sink/req_sync_0_s0
 rom_sink/ack_sync_0_s0
 iosys/transport_hold_sync_0_s0
 iosys/uart_rx_r_s0
 rom_game_hold_sync_0_s1
}]
set_false_path -to [get_regs {
 rom_sink/op_hold_*
 rom_sink/offset_hold_*
 rom_sink/requested_total_*
 rom_sink/digest_hold_*
 rom_sink/count_hold_*
 rom_sink/block_bank_s0
}]

# CRT stage1 acknowledged frame-boundary mailbox.

set_false_path -to [get_regs {s2h/crt_stage1.crt_config/req_sync_0_s0 s2h/crt_stage1.crt_config/ack_sync_0_s0}]
set_false_path -to [get_regs {
 s2h/crt_stage1.crt_config/pending_0_s0
 s2h/crt_stage1.crt_config/pending_1_s0
 s2h/crt_stage1.crt_config/pending_2_s0
 s2h/crt_stage1.crt_config/pending_3_s0
 s2h/crt_stage1.crt_config/pending_4_s0
 s2h/crt_stage1.crt_config/pending_5_s0
 s2h/crt_stage1.crt_config/pending_6_s0
 s2h/crt_stage1.crt_config/pending_7_s0
 s2h/crt_stage1.crt_config/pending_8_s0
 s2h/crt_stage1.crt_config/pending_9_s0
 s2h/crt_stage1.crt_config/pending_10_s0
 s2h/crt_stage1.crt_config/pending_11_s0
 s2h/crt_stage1.crt_config/pending_12_s0
 s2h/crt_stage1.crt_config/pending_13_s0
 s2h/crt_stage1.crt_config/pending_14_s0
 s2h/crt_stage1.crt_config/pending_15_s0
 s2h/crt_stage1.crt_config/pending_16_s0
 s2h/crt_stage1.crt_config/pending_17_s0
 s2h/crt_stage1.crt_config/pending_18_s0
 s2h/crt_stage1.crt_config/pending_19_s0
 s2h/crt_stage1.crt_config/pending_20_s0
 s2h/crt_stage1.crt_config/pending_21_s0
 s2h/crt_stage1.crt_config/pending_22_s0
 s2h/crt_stage1.crt_config/pending_23_s0
 s2h/crt_stage1.crt_config/pending_24_s0
 s2h/crt_stage1.crt_config/pending_25_s0
 s2h/crt_stage1.crt_config/pending_26_s0
 s2h/crt_stage1.crt_config/pending_27_s0
 s2h/crt_stage1.crt_config/pending_28_s0
 s2h/crt_stage1.crt_config/pending_29_s0
 s2h/crt_stage1.crt_config/pending_30_s0
 s2h/crt_stage1.crt_config/pending_31_s0
 s2h/crt_stage1.crt_config/applied_config_0_s0
 s2h/crt_stage1.crt_config/applied_config_1_s0
 s2h/crt_stage1.crt_config/applied_config_2_s0
 s2h/crt_stage1.crt_config/applied_config_3_s0
 s2h/crt_stage1.crt_config/applied_config_4_s0
 s2h/crt_stage1.crt_config/applied_config_5_s0
 s2h/crt_stage1.crt_config/applied_config_6_s0
 s2h/crt_stage1.crt_config/applied_config_7_s0
 s2h/crt_stage1.crt_config/applied_config_8_s0
 s2h/crt_stage1.crt_config/applied_config_9_s0
 s2h/crt_stage1.crt_config/applied_config_10_s0
 s2h/crt_stage1.crt_config/applied_config_11_s0
 s2h/crt_stage1.crt_config/applied_config_12_s0
 s2h/crt_stage1.crt_config/applied_config_13_s0
 s2h/crt_stage1.crt_config/applied_config_14_s0
 s2h/crt_stage1.crt_config/applied_config_15_s0
 s2h/crt_stage1.crt_config/applied_config_16_s0
 s2h/crt_stage1.crt_config/applied_config_17_s0
 s2h/crt_stage1.crt_config/applied_config_18_s0
 s2h/crt_stage1.crt_config/applied_config_19_s0
 s2h/crt_stage1.crt_config/applied_config_20_s0
 s2h/crt_stage1.crt_config/applied_config_21_s0
 s2h/crt_stage1.crt_config/applied_config_22_s0
 s2h/crt_stage1.crt_config/applied_config_23_s0
 s2h/crt_stage1.crt_config/applied_config_24_s0
 s2h/crt_stage1.crt_config/applied_config_25_s0
 s2h/crt_stage1.crt_config/applied_config_26_s0
 s2h/crt_stage1.crt_config/applied_config_27_s0
 s2h/crt_stage1.crt_config/applied_config_28_s0
 s2h/crt_stage1.crt_config/applied_config_29_s0
 s2h/crt_stage1.crt_config/applied_config_30_s0
 s2h/crt_stage1.crt_config/applied_config_31_s0
}]

# Status mailbox: synchronized request/ack and payload held through capture.
set_false_path -to [get_regs {s2h/load_display.status_cdc/ack_sync_0_s0 s2h/load_display.status_cdc/toggle_sync_0_s0 s2h/load_display.status_cdc/dst_data_*}]
