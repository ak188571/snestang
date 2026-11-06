#!/usr/bin/env bash
set -euo pipefail
export PATH=/ucrt64/bin:/usr/bin:$PATH
export MSYS2_ARG_CONV_EXCL='*'
cd "$(dirname "$0")/../.."
mkdir -p build-crt/uart build-crt/video
flags=(-CFLAGS '-BC:/msys64/ucrt64/bin/ -std=c++17' -LDFLAGS '-BC:/msys64/ucrt64/bin/ -mconsole')
sed 's/ASSERTION_ERROR PARAMETER_OUT_OF_RANGE("[^"]*");/initial $fatal(1,"UART parameter range");/' \
 src/iosys/uart_fixed.v > build-crt/uart_fixed_test.v
verilator --binary --timing --assert -Wno-fatal -DSIM --top-module tb_snes_crt_uart \
 --Mdir build-crt/uart -j 4 tests/crt/tb_snes_crt_uart.sv src/iosys/iosys_bl616.v \
 build-crt/uart_fixed_test.v src/iosys/tc_crt_config.sv "${flags[@]}" > build-crt/uart-build.log 2>&1
./build-crt/uart/Vtb_snes_crt_uart
# Real Console138K clock period, declared UART frequency, external 2 Mbaud.
verilator --binary --timing --assert -Wno-fatal -DSIM --top-module tb_snes_crt_uart \
 -GFREQ=21484000 -GHALF_PERIOD=23.25 -GBIT_NS=500.0 \
 --Mdir build-crt/uart-real -j 4 tests/crt/tb_snes_crt_uart.sv src/iosys/iosys_bl616.v \
 build-crt/uart_fixed_test.v src/iosys/tc_crt_config.sv "${flags[@]}" > build-crt/uart-real-build.log 2>&1
./build-crt/uart-real/Vtb_snes_crt_uart
# Published OSD1 baseline, available in a fresh GitHub clone.
git show 32433c52398ab1c65047cabfc77fafb34648ed35:src/snes2hdmi.v | \
 sed 's/module snes2hdmi (/module baseline_snes2hdmi (/' > build-crt/baseline_snes2hdmi.v
verilator --binary --timing --assert -Wno-fatal --top-module tb_snes_crt_video \
 --Mdir build-crt/video -j 4 tests/crt/tb_snes_crt_video.sv tests/crt/hdmi_stub.sv \
 build-crt/baseline_snes2hdmi.v src/snes2hdmi.v src/dual_clk_fifo.v \
 src/iosys/tc_osd_layer.sv src/iosys/tc_crt_config.sv src/iosys/tc_crt_bypass.sv \
 "${flags[@]}" > build-crt/video-build.log 2>&1
./build-crt/video/Vtb_snes_crt_video

verilator --binary --timing --assert -Wno-fatal --top-module tb_snes_crt_config \
 --Mdir build-crt/config -j 4 tests/crt/tb_snes_crt_config.sv \
 src/iosys/tc_crt_config.sv src/iosys/tc_crt_bypass.sv "${flags[@]}" > build-crt/config-build.log 2>&1
./build-crt/config/Vtb_snes_crt_config

verilator --binary --timing --assert -Wno-fatal -DBLOCK_SAFE --top-module tb_snes_input_release \
 --Mdir build-crt/input -j 4 tests/crt/tb_snes_input_release.sv src/controller_adapter.sv \
 "${flags[@]}" > build-crt/input-build.log 2>&1
./build-crt/input/Vtb_snes_input_release
