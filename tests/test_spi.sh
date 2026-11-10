#!/bin/bash
# SPI NOR flash end-to-end test: U-Boot atcspi200 driver + spi-nor stack on
# the AE350 QEMU ATCSPI200 model with an MX25L1606E (2 MiB) flash.
#
#   ./test_spi.sh [port]          預設 port 4450
#
# 環境變數
#   UBOOT=<elf>   受測 U-Boot ELF（預設 /home/spoto/claude_workspace/build-spi/out/u-boot）
#   IMG=<file>    SPI flash 背後的映像（每次測試重新產生，預設 run/spi-test-<port>.img）
#   SEED=<n>      映像隨機內容的種子
#   LOG=<file>    完整 console log（預設 ../results/spi_verify_<日期>.txt）
#
# 會開兩次機：第一次 sf probe/read/erase/write/update/test + saveenv，
# 關機後在 host 端比對映像，第二次確認 env 與資料都保存下來。
# 每一步印 PASS/FAIL，全部通過 exit 0。

set -u
W="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=${1:-4450}
export UBOOT=${UBOOT:-/home/spoto/claude_workspace/build-spi/out/u-boot}
export SD=${SD:-none}
IMG=${IMG:-$W/run/spi-test-${PORT}.img}
SEED=${SEED:-21328}
RESULTS=/home/spoto/claude_workspace/results
mkdir -p "$RESULTS" "$W/run"
LOG=${LOG:-$RESULTS/spi_verify_$(date +%Y%m%d_%H%M%S).txt}

if [ -n "$(pgrep -f "telnet:127.0.0.1:${PORT},server")" ]; then
    echo "port $PORT 已有 instance 在跑，請先 '$W/ae350.sh stop $PORT'" >&2
    exit 2
fi

echo "U-Boot : $UBOOT"
echo "image  : $IMG"
echo "log    : $LOG"
python3 -I "$W/test_spi.py" "$W/ae350.sh" "$PORT" "$IMG" "$LOG" "$SEED"
rc=$?
# 保險：不論成敗都只關自己的 port
[ -n "$(pgrep -f "telnet:127.0.0.1:${PORT},server")" ] && "$W/ae350.sh" stop "$PORT" >/dev/null
echo "log saved to $LOG"
exit $rc
