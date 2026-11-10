# AE350 U-Boot driver 驗證：SPI NOR flash 與 SD/MMC

在 Andes QEMU 的 `andes_ae350` machine 上驗證 U-Boot `ae350_rv64_defconfig` 的兩個 driver：

| Driver | U-Boot | QEMU 模型 | 結果 |
|---|---|---|---|
| SPI NOR flash | `drivers/spi/atcspi200_spi.c` | `hw/ssi/atcspi200.c`（新增） | 33/33 PASS |
| SD/MMC | `drivers/mmc/ftsdc010_mci.c` | `hw/sd/atfsdc010.c` | 133/133 PASS |

## 基準版本

| 元件 | 來源 | 基準 commit |
|---|---|---|
| U-Boot | u-boot mainline | `v2026.10-746-gfed92546960` |
| QEMU | github.com/andestech/qemu，branch `ast-v5_4_2-release`（QEMU 9.2.0） | `3290262` |
| Toolchain | bootlin `riscv64-lp64d--glibc--stable-2026.08-1` | |

## 目錄

    uboot/0001-spi-atcspi200-limit-transfer-size-to-512.patch   U-Boot patch
    uboot/files/                                               修改後的完整檔案
    qemu/0001-ae350-atcspi200-model-and-atfsdc010-card-detect.patch   QEMU patch（含新增檔）
    qemu/files/                                                修改後 / 新增的完整檔案
    tests/                                                     啟動腳本與測試腳本
    results/                                                   驗證 console log

## 修改內容

### U-Boot：`atcspi200_spi.c` 跨 64 KiB 位址錯誤（bug fix）

傳輸大於 512 bytes 時，`__atcspi200_spi_xfer()` 會自行切段並重送命令，更新位址的方式是
`cmd_buf[1..3]` 各自相加、沒有進位。只要某段跨過 64 KiB 邊界，位址就會繞回該 64K 區塊開頭，
造成讀寫錯位（未修正版只過 26/33，見 `results/spi_verify_20261110_baseline_unfixed_driver.txt`）。

修法：新增 `child_pre_probe`，把 `slave->max_read_size` / `max_write_size` 設成
`MAX_TRANSFER_LEN`（512，WrTranCnt/RdTranCnt 為 9-bit 欄位的上限），讓 SPI-NOR 核心自己切段並正確計算位址。

### QEMU：新增 ATCSPI200 SPI 控制器模型

- `hw/ssi/atcspi200.c`、`include/hw/ssi/atcspi200.h`：IdRev、TransFmt、TransCtrl、Cmd、Addr、Data、
  Ctrl、Status、IntrEn/IntrSt、Timing、MemCtrl、Config；10 種 TransMode、FIFO（預設深度 16）、
  DataMerge、LSB-first、FIFO 空/滿時 stall、end/overrun 中斷。
- `hw/riscv/andes_ae350.c`：SPI1（0xf0b00000，IRQ 4）與 SPI2（0xf0f00000，IRQ 5）原本是
  `create_unimplemented_device`，改為 ATCSPI200。SPI1 固定接 mx25l1606e（2 MiB，4K sector），
  以 `-drive if=mtd,index=0` 提供 backing image；SPI2 有給 `if=mtd,index=1` 時才接 flash。
- `hw/riscv/Kconfig`、`hw/ssi/Kconfig`、`hw/ssi/meson.build`、`include/hw/riscv/andes_ae350.h`：對應設定。

### QEMU：`atfsdc010.c` card detect

原本插拔卡只驅動沒接線的 GPIO，STATUS 永遠回報有卡，U-Boot 無卡時每個指令都要等 timeout。
現在 STATUS bit 11 `CARD_DETECT`（1 = 無卡）、bit 12 `WRITE_PROT` 反映實際狀態，插拔時設 bit 10 `CARD_CHANGE`。

## 套用與建置

    # U-Boot
    cd u-boot && git apply /path/to/uboot/0001-*.patch
    make ae350_rv64_defconfig && make CROSS_COMPILE=riscv64-linux- -j$(nproc)

    # QEMU
    cd andes-qemu && git apply /path/to/qemu/0001-*.patch
    ninja -C build qemu-system-riscv64

MMC 測試另需在 `.config` 開啟：`CMD_EXT4_WRITE EXT4_WRITE CMD_GPT RANDOM_UUID CMD_MD5SUM CMD_HASH CMD_SETEXPR CMD_LSBLK`。

## 測試

`tests/ae350.sh` 為啟動 / 送指令腳本（說明見 `tests/README.md`），新增 `SPI=<img>`、`SPI2=<img>` 參數。

    UBOOT=<u-boot ELF> ./test_spi.sh 4450
    UBOOT=<u-boot ELF> ./test_mmc.sh          # PORT 預設 4460

注意：腳本內 QEMU 路徑、預設 U-Boot 路徑與 log 輸出目錄是寫死的本機路徑
（`/home/spoto/claude_workspace/...`），在其他機器上需修改 `ae350.sh` 的 `QEMU=`，並以環境變數指定 `UBOOT` 等。

## 已知限制

- SPI fast read (0x0B)：QEMU m25p80 把 dummy 視為 8 個 byte，控制器只送 1 個，資料會偏移。目前 DTS 未開 `m25p,fast-read`，不受影響。
- ATCSPI200 模型未實作 DMA、DirectIO、memory-mapped 讀取窗口、dual/quad 時序；SPI 時脈視為無限快。
- SPI2 只驗證到暫存器可存取，未接 flash 測試。
- 暫存器 reset 值等細節依 U-Boot driver 用法與 ATCSPI200 常見配置推得，未與 datasheet 核對。
- SD 寫入保護無法測（QEMU 不接受唯讀 SD 映像）；資料 CRC 錯誤 / timeout 路徑 QEMU 不會產生，未測。
- `atcspi200_spi.c` 其他未修問題：timeout 只在 probe 時設定；mode 直接 OR 進 TransFmt，遇 `spi-cs-high` 或 dual/quad 會寫壞欄位；
  driver 內部切段的進位 bug 對 >512 bytes 的 raw `spi_xfer` 呼叫者仍存在。
