#!/bin/bash
# AE350 U-Boot on Andes QEMU — telnet serial console
#
#   ./ae350.sh start [port]    背景啟動，UART 導到 telnet port（預設 4444）
#   ./ae350.sh attach [port]   telnet 連上 console（需要真正的終端機）
#   ./ae350.sh exec [-p port] "cmd" ...
#                              非互動送 U-Boot 指令並印出結果
#   ./ae350.sh run [port]      start + attach 一次完成
#   ./ae350.sh status          顯示執行中的 instance
#   ./ae350.sh stop [port]     關掉（不給 port 則全關）
#   ./ae350.sh log             顯示最近一次的啟動訊息
#
# 選項（環境變數）
#   UBOOT=<elf>    預設 /home/spoto/uboot/u-boot        (必須是 ELF，不是 .bin)
#   DTB=<dtb>      預設 $W/ae350_64.dtb
#   SD=<img>       預設 $W/sd.img                       設為 none 可不掛卡
#   SPI=<img>      SPI1 NOR flash (MX25L1606E, 2MiB) 映像，預設 none（flash 內容為空白 0xFF、不保存）
#   SPI2=<img>     SPI2 上的 NOR flash 映像，預設 none（不掛 flash）
#   SMP=<n>        預設 4
#   MEM=<size>     預設 1G
#   CPU=<model>    預設 andes-ax25mp
#   NOWAIT=1       不等 telnet 連線就開機（會漏掉開頭 log）

set -u

W="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU=/home/spoto/claude_workspace/andes-qemu/build/qemu-system-riscv64

UBOOT=${UBOOT:-/home/spoto/uboot/u-boot}
DTB=${DTB:-$W/ae350_64.dtb}
SD=${SD:-$W/sd.img}
SPI=${SPI:-none}
SPI2=${SPI2:-none}
SMP=${SMP:-4}
MEM=${MEM:-1G}
CPU=${CPU:-andes-ax25mp}
NOWAIT=${NOWAIT:-0}

LOGDIR=$W/run
mkdir -p "$LOGDIR"

die() { echo "錯誤: $*" >&2; exit 1; }

preflight() {
    [ -x "$QEMU" ] || die "找不到 QEMU: $QEMU（請先建置 andes-qemu）"
    [ -f "$UBOOT" ] || die "找不到 U-Boot: $UBOOT"
    head -c4 "$UBOOT" | grep -q $'\x7fELF' \
        || die "$UBOOT 不是 ELF — andes_ae350 的 -bios 只吃 ELF，請用 u-boot 而非 u-boot.bin"
    [ -f "$DTB" ] || die "找不到 DTB: $DTB"
    if [ "$SD" != none ] && [ ! -f "$SD" ]; then
        die "找不到 SD 映像: $SD（用 SD=none 可不掛卡）"
    fi
    local f
    for f in "$SPI" "$SPI2"; do
        [ "$f" = none ] && continue
        [ -f "$f" ] || die "找不到 SPI flash 映像: $f（可用 'truncate -s 2M' 或 'head -c 2M /dev/zero | tr \\0 \\377' 建立）"
        [ "$(stat -c %s "$f")" -ge 2097152 ] || die "SPI flash 映像 $f 小於 2MiB（MX25L1606E）"
    done
}

pid_on_port() { pgrep -f "telnet:127.0.0.1:${1},server" | head -1; }

cmd_start() {
    local port=${1:-4444}
    preflight
    local existing; existing=$(pid_on_port "$port")
    [ -n "$existing" ] && die "port $port 已有 instance 在跑 (pid $existing)"

    local waitopt=wait
    [ "$NOWAIT" = 1 ] && waitopt=nowait

    local args=(
        -M andes_ae350 -cpu "$CPU" -smp "$SMP" -m "$MEM"
        -display none
        -serial "telnet:127.0.0.1:${port},server,${waitopt}"
        -bios "$UBOOT"
        -dtb "$DTB"
    )
    [ "$SD" != none ] && args+=( -drive "file=${SD},if=sd,format=raw" )
    [ "$SPI" != none ] && args+=( -drive "file=${SPI},if=mtd,index=0,format=raw" )
    [ "$SPI2" != none ] && args+=( -drive "file=${SPI2},if=mtd,index=1,format=raw" )

    nohup "$QEMU" "${args[@]}" > "$LOGDIR/qemu-${port}.log" 2>&1 &
    local pid=$!
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "啟動失敗:" >&2; cat "$LOGDIR/qemu-${port}.log" >&2; exit 1
    fi
    echo "$pid" > "$LOGDIR/qemu-${port}.pid"

    echo "AE350 QEMU 已啟動"
    echo "  pid      : $pid"
    echo "  console  : telnet localhost $port"
    echo "  U-Boot   : $UBOOT"
    echo "  DTB      : $DTB"
    echo "  SD       : $SD"
    echo "  SPI      : $SPI"
    [ "$SPI2" != none ] && echo "  SPI2     : $SPI2"
    [ "$waitopt" = wait ] && echo "  (wait 模式：telnet 接上才開始開機，不會漏掉開頭 log)"
}

cmd_attach() {
    local port=${1:-4444}
    [ -n "$(pid_on_port "$port")" ] || die "port $port 沒有 instance，先跑 '$0 start $port'"
    echo "連線到 localhost:$port  —  離開按 Ctrl-] 然後輸入 quit"
    exec telnet localhost "$port"
}

cmd_run() {
    local port=${1:-4444}
    [ -z "$(pid_on_port "$port")" ] && cmd_start "$port"
    echo
    cmd_attach "$port"
}

cmd_status() {
    local found=0
    while read -r pid port; do
        [ -z "$pid" ] && continue
        found=1
        printf "pid %-8s port %-6s  telnet localhost %s\n" "$pid" "$port" "$port"
    done < <(pgrep -af 'qemu-system-riscv64.*andes_ae350' \
             | grep -oE '^([0-9]+).*telnet:127\.0\.0\.1:([0-9]+)' \
             | sed -E 's/^([0-9]+).*telnet:127\.0\.0\.1:([0-9]+)/\1 \2/')
    [ "$found" = 0 ] && echo "沒有執行中的 AE350 instance"
    return 0
}

cmd_stop() {
    if [ $# -ge 1 ]; then
        local pid; pid=$(pid_on_port "$1")
        [ -z "$pid" ] && die "port $1 沒有 instance"
        kill "$pid" && echo "已關閉 port $1 (pid $pid)"
        rm -f "$LOGDIR/qemu-$1.pid"
    else
        if pkill -f 'qemu-system-riscv64.*andes_ae350'; then
            echo "已關閉所有 AE350 instance"
            rm -f "$LOGDIR"/qemu-*.pid
        else
            echo "沒有執行中的 AE350 instance"
        fi
    fi
    return 0
}

cmd_exec() {
    # ./ae350.sh exec [-p port] "cmd1" "cmd2" ...   非互動送指令、收輸出
    local port=4444
    if [ "${1:-}" = "-p" ]; then port=$2; shift 2; fi
    [ $# -ge 1 ] || die "用法: $0 exec [-p port] \"cmd\" [\"cmd\" ...]"
    [ -n "$(pid_on_port "$port")" ] || die "port $port 沒有 instance，先跑 '$0 start $port'"
    python3 -I "$W/ubcmd.py" "$port" 40 "$@"
}

cmd_log() {
    local port=${1:-4444}
    local f=$LOGDIR/qemu-${port}.log
    [ -f "$f" ] || die "找不到 $f"
    cat "$f"
}

case "${1:-run}" in
    start)  shift; cmd_start "$@" ;;
    exec)   shift; cmd_exec "$@" ;;
    attach) shift; cmd_attach "$@" ;;
    run)    shift; cmd_run "$@" ;;
    status) shift; cmd_status "$@" ;;
    stop)   shift; cmd_stop "$@" ;;
    log)    shift; cmd_log "$@" ;;
    -h|--help|help) sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//' ;;
    *) die "未知指令 '${1}'（可用: start attach exec run status stop log help）" ;;
esac
