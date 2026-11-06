#!/usr/bin/env bash
set -euo pipefail
export PATH=/ucrt64/bin:/usr/bin:$PATH
export MSYS2_ARG_CONV_EXCL='*'
cd "$(dirname "$0")/../.."
mkdir -p build-crt/blur build-crt/blur-video build-crt/blur-uart
flags=(-CFLAGS '-BC:/msys64/ucrt64/bin/ -std=c++17' -LDFLAGS '-BC:/msys64/ucrt64/bin/ -mconsole')
verilator --binary --timing --assert -Wno-fatal --top-module tb_crt_blur \
 --Mdir build-crt/blur -j 4 tests/crt/tb_crt_blur.sv src/iosys/crt_filter.sv \
 "${flags[@]}" > build-crt/blur-build.log 2>&1
./build-crt/blur/Vtb_crt_blur
sed 's/ASSERTION_ERROR PARAMETER_OUT_OF_RANGE("[^"]*");/initial $fatal(1,"UART parameter range");/' \
 src/iosys/uart_fixed.v > build-crt/uart_fixed_test.v
verilator --binary --timing --assert -Wno-fatal -DSIM --top-module tb_snes_crt_uart \
 -GEXPECT_BLUR=1 -GFREQ=21484000 -GHALF_PERIOD=23.25 -GBIT_NS=500.0 \
 --Mdir build-crt/blur-uart -j 4 tests/crt/tb_snes_crt_uart.sv src/iosys/iosys_bl616.v \
 build-crt/uart_fixed_test.v src/iosys/tc_crt_config.sv "${flags[@]}" > build-crt/blur-uart-build.log 2>&1
./build-crt/blur-uart/Vtb_snes_crt_uart
# Compare with the published SNES path, not another copy of the new prefetch.
git show 32433c52398ab1c65047cabfc77fafb34648ed35:src/snes2hdmi.v | \
 sed 's/module snes2hdmi (/module baseline_snes2hdmi (/' > build-crt/baseline_snes2hdmi.v
verilator --binary --timing --assert -Wno-fatal --top-module tb_snes_crt_blur_video \
 --Mdir build-crt/blur-video -j 4 tests/crt/tb_snes_crt_blur_video.sv tests/crt/hdmi_stub.sv \
 build-crt/baseline_snes2hdmi.v src/snes2hdmi.v src/dual_clk_fifo.v \
 src/iosys/tc_osd_layer.sv src/iosys/tc_crt_config.sv src/iosys/tc_crt_bypass.sv src/iosys/crt_filter.sv \
 "${flags[@]}" > build-crt/blur-video-build.log 2>&1
./build-crt/blur-video/Vtb_snes_crt_blur_video
