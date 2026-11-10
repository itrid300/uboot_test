# AE350 U-Boot on Andes QEMU

U-Boot 2026.10 (`ae350_rv64_defconfig`) 跑在 Andes QEMU fork 的 `andes_ae350` machine 上。

## 快速開始

    ./ae350.sh run            # 啟動 + 連上 console（預設 port 4444）

離開 telnet：`Ctrl-]` 然後輸入 `quit`（QEMU 會繼續在背景跑，可再 attach）。

## 子指令

| 指令 | 說明 |
|---|---|
| `./ae350.sh start [port]`  | 背景啟動，UART 導到 telnet port |
| `./ae350.sh attach [port]` | telnet 連上 console（**需要真正的終端機**） |
| `./ae350.sh exec [-p port] "cmd" ...` | 非互動送 U-Boot 指令、印出結果 |
| `./ae350.sh run [port]`    | start + attach |
| `./ae350.sh status`        | 列出執行中的 instance |
| `./ae350.sh stop [port]`   | 關閉（不給 port 則全關） |
| `./ae350.sh log [port]`    | 顯示 QEMU 啟動訊息 |

## 非互動操作

`attach` 走 telnet，在沒有 TTY 的環境（腳本、CI、agent）送不進按鍵，autoboot
會照樣跑完。這種場合用 `exec`，它走 raw socket、會自己敲鍵中斷 autoboot：

    ./ae350.sh exec "mmc info" "fatls mmc 0:0"
    ./ae350.sh exec -p 5555 "bdinfo" "dm tree"

## 環境變數

    UBOOT=<elf>   U-Boot ELF，預設 /home/spoto/uboot/u-boot
    DTB=<dtb>     預設 ./ae350_64.dtb
    SD=<img>      預設 ./sd.img，設 none 不掛卡
    SPI=<img>     SPI1 NOR flash 映像（-drive if=mtd,index=0），預設 none
                  flash 一律存在（MX25L1606E, 2MiB）；none 時內容是空白 0xFF、關機即消失
    SPI2=<img>    SPI2 上的 flash（if=mtd,index=1），預設 none = SPI2 不掛 flash
    SMP=<n>       預設 4
    MEM=<size>    預設 1G
    CPU=<model>   預設 andes-ax25mp
    NOWAIT=1      不等 telnet 連線就開機

範例：

    SMP=1 MEM=512M ./ae350.sh run 5555
    SD=none ./ae350.sh start

## 兩個必要條件（踩過的坑）

1. **`-bios` 只吃 ELF**。`andes_ae350.c` 的 `andes_load_elf()` 會對 raw binary `exit(1)`。
   要給 `u-boot`，不是 `u-boot.bin`。腳本有擋。
2. **必須傳 `-dtb`**。不給的話 QEMU 自產 FDT，不含 MMC / SPI / MAC 節點，
   開機後 `MMC:` 是空的、網路也不見。`ae350_64.dtb` 由 U-Boot 的
   `arch/riscv/dts/ae350_64.dts` 編出（需先拿掉 `binman.dtsi` 與
   `ae350-u-boot.dtsi` 兩個 include，否則 dtc 解析 kconfig.h 失敗）。

## 檔案

    ae350.sh               啟動 / 連線 / 管理腳本
    ubcmd.py               exec 子指令用的 raw socket client
    ae350_64_hw.dts        去掉 binman include 的可編譯版 DTS
    ae350_64.dtb           上面編出來的 DTB
    sd.img                 64MB FAT16 測試卡，內含 HELLO.TXT
    test_spi.sh / .py      SPI flash 端到端測試（兩次開機、PASS/FAIL 表）
    ae350-interactive.txt  先前完整 console log（含 mmc info / dm tree / bdinfo）
    run/                   各 instance 的 QEMU 啟動訊息與 pid

## 相依

    QEMU   /home/spoto/claude_workspace/andes-qemu/build/qemu-system-riscv64
           source: github.com/andestech/qemu  branch ast-v5_4_2-release (QEMU 9.2.0)
    U-Boot /home/spoto/uboot  (v2026.10-746-gfed92546960)
           toolchain: /home/spoto/claude_workspace/toolchains/riscv64-lp64d--glibc--stable-2026.08-1

## 已知無害警告

- `Unknown flash on Bank 1` — QEMU 的 MROM 不模擬 CFI chip
- `*** Warning - bad CRC, using default environment` — SPI flash 的 env 區（0x140000）還是空的；
  `saveenv` 後就不會再出現（要保存請用 `SPI=<img>`）

## SPI NOR flash

QEMU 端 `hw/ssi/atcspi200.c` 是 ATCSPI200 控制器模型（0xf0b00000 IRQ 4、0xf0f00000 IRQ 5），
SPI1 上掛 m25p80 的 `mx25l1606e`（JEDEC c2 20 15，4K sector）。

    head -c 2M /dev/zero | tr '\0' '\377' > spi.img      # 空白 flash
    SPI=$PWD/spi.img ./ae350.sh start 4450
    ./test_spi.sh 4450      # 完整 sf / saveenv 驗證，log 存到 ../results/spi_verify_*.txt
