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
