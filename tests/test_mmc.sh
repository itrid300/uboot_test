#!/bin/bash
# test_mmc.sh — AE350 U-Boot SD/MMC (ATFSDC010 / ftsdc010_mci) end-to-end test on Andes QEMU
#
#   ./test_mmc.sh                 建 image → 開機 → 跑 U-Boot 指令 → 關機 → host 端驗證
#
# 四個 session（s0 無卡，s1-s3 各用一張自建的 SD image，不動 ./sd.img）:
#   s0  SD=none：STATUS.CARD_DETECT、mmc rescan 回報 no card present 而非 CMD timeout
#   s1  128 MiB SDSC, MBR: p1 FAT16 30M, p2 ext4 32M, 後 64M 不分割當 raw 區
#         mmc info/part/dev、單/多/奇數 block 讀寫、8 MiB 傳輸、未對齊 buffer、
#         最後一個 block、越界寫入、mmc erase、fatwrite/fatload、ext4write/ext4load、rescan
#   s2  2 GiB SDSC 邊界（byte addressing 上限），空白卡
#         gpt write/verify、part list、靠近 2 GiB 的 raw 讀寫
#   s3  8 GiB SDHC (block addressing)，host 先用 sgdisk 建 GPT: p1 FAT32 @6GiB, p2 ext4 @6.5GiB
#         讀 host 寫的 backup GPT (最後一個 LBA)、>4 GiB 的 raw 讀寫/erase、FAT32/ext4 寫入
# 註: FAT32 的 FSInfo free count U-Boot 不會更新，fsck.fat 只報這一項時視為 PASS
# 註: ext4 用 -O ^metadata_csum 建，U-Boot ext4write 不支援 metadata_csum（RO_COMPAT 0x400，會拒寫）
# 每個 session 結束後關 QEMU，再在 host 上用 dd/md5sum/mtools/debugfs/fsck/sgdisk 驗證
# 資料真的寫進 backing file。
#
# 環境變數
#   PORT=4460                                  telnet port（只會 stop 這個 port）
#   UBOOT=/home/spoto/claude_workspace/build-mmc/out/u-boot
#   WORK=/home/spoto/claude_workspace/build-mmc/mmctest   image 與每步輸出
#   LOG=/home/spoto/claude_workspace/results/mmc_verify_<date>.txt
#   KEEP=1                                     保留 image（預設跑完刪掉 2G/8G sparse image）
#
# U-Boot 需要: CMD_MMC MMC_WRITE CMD_FAT FAT_WRITE CMD_EXT4_WRITE CMD_GPT RANDOM_UUID
#              CMD_PART CMD_MD5SUM CMD_RANDOM（ae350_rv64_defconfig + scripts/config 開後三個以外的幾個）
# 結束碼: 0 全 PASS，1 有 FAIL

set -u
W="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=${PORT:-4460}
UBOOT=${UBOOT:-/home/spoto/claude_workspace/build-mmc/out/u-boot}
WORK=${WORK:-/home/spoto/claude_workspace/build-mmc/mmctest}
STAMP=$(date +%Y%m%d_%H%M%S)
LOG=${LOG:-/home/spoto/claude_workspace/results/mmc_verify_${STAMP}.txt}
KEEP=${KEEP:-0}

# guest RAM buffers (DRAM 0..1GiB, U-Boot relocates to ~0x3ff00000)
A=0x10000000   # random source pattern (16 MiB)
B=0x12000000   # readback buffer
C=0x14000000   # 0xff reference for erase
PATSZ=0x1000000

mkdir -p "$WORK" "$(dirname "$LOG")"
: > "$LOG"
NPASS=0; NFAIL=0; RESULTS=()

say()  { echo "$*" | tee -a "$LOG"; }
rec()  { # rec PASS|FAIL step detail
    local r=$1 step=$2; shift 2
    RESULTS+=("$(printf '%-4s  %-34s %s' "$r" "$step" "$*")")
    [ "$r" = PASS ] && NPASS=$((NPASS+1)) || NFAIL=$((NFAIL+1))
    say "$(printf '[%s] %-34s %s' "$r" "$step" "$*")"
}
die()  { say "FATAL: $*"; exit 2; }
tool() { command -v "$1" >/dev/null 2>&1 || [ -x "/usr/sbin/$1" ] || [ -x "/sbin/$1" ] || die "missing host tool $1"; }
for t in sfdisk sgdisk mkfs.vfat mkfs.ext4 debugfs e2fsck fsck.fat mcopy dd md5sum python3; do tool "$t"; done
export PATH="$PATH:/usr/sbin:/sbin"
[ -f "$UBOOT" ] || die "U-Boot ELF not found: $UBOOT"

# ---------------------------------------------------------------- console client
# 一條 telnet 連線跑完整個 session：等 autoboot 倒數→按鍵→逐條送指令，每條等 prompt
# 回來（各自 timeout），輸出存 <outdir>/<id>.out
cat > "$WORK/ubsess.py" <<'PY'
import socket, sys, time, re, os
port = int(sys.argv[1]); cmdfile = sys.argv[2]; outdir = sys.argv[3]
PROMPT = b"\nRISC-V # "
s = socket.create_connection(("127.0.0.1", port), timeout=10); s.settimeout(0.2)
buf = b""
def rd():
    global buf
    try:
        d = s.recv(65536)
        if not d: raise EOFError("console closed")
        buf += d
    except socket.timeout:
        pass
def clean(b):
    o = bytearray(); i = 0
    while i < len(b):
        if b[i] == 0xff and i + 2 < len(b): i += 3; continue
        o.append(b[i]); i += 1
    t = o.decode("utf-8", "replace").replace("\r", "")
    return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", t)
t0 = time.time()
while b"Hit any key" not in buf:
    rd()
    if time.time() - t0 > 90: print(clean(buf)); print("@@BOOT TIMEOUT"); sys.exit(2)
s.sendall(b"\r")
t0 = time.time()
while not buf.endswith(PROMPT):
    rd()
    if time.time() - t0 > 20: print(clean(buf)); print("@@PROMPT TIMEOUT"); sys.exit(2)
open(os.path.join(outdir, "boot.out"), "w").write(clean(buf))
print(clean(buf)); sys.stdout.flush()
rc = 0
for line in open(cmdfile):
    line = line.rstrip("\n")
    if not line or line.startswith("#"): continue
    sid, tmo, cmd = line.split("|", 2)
    buf = b""
    s.sendall(cmd.encode() + b"\r")
    t0 = time.time(); ok = False
    while time.time() - t0 < float(tmo):
        rd()
        if buf.endswith(PROMPT): ok = True; break
    out = clean(buf)
    if not ok: out += "\n@@TIMEOUT after %ss\n" % tmo; rc = 1
    open(os.path.join(outdir, sid + ".out"), "w").write(out)
    sys.stdout.write("--- [%s] (%.1fs)\n%s" % (sid, time.time() - t0, out.rstrip("# ").rstrip("RISC-V").rstrip() + "\n"))
    sys.stdout.flush()
    if not ok: break
s.close(); sys.exit(rc)
PY

# ---------------------------------------------------------------- helpers
qpid() { pgrep -f "telnet:127.0.0.1:${PORT},server" | head -1; }
stop_qemu() {
    local pid; pid=$(qpid)
    [ -z "$pid" ] && return 0
    (cd "$W" && ./ae350.sh stop "$PORT") >>"$LOG" 2>&1
    for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.2; done
    say "WARN: qemu pid $pid did not exit"
}
OUT=""
run_session() {   # run_session <name> <img> <cmdfile>
    local name=$1 img=$2 cmds=$3
    OUT=$WORK/$name; rm -rf "$OUT"; mkdir -p "$OUT"
    stop_qemu
    say ""; say "################ session $name  SD=$img ($( [ "$img" = none ] && echo no card || du -h --apparent-size "$img" | cut -f1))"
    (cd "$W" && UBOOT=$UBOOT SD=$img ./ae350.sh start "$PORT") >>"$LOG" 2>&1 \
        || { rec FAIL "$name: qemu start" "see log"; return 1; }
    python3 -I "$WORK/ubsess.py" "$PORT" "$cmds" "$OUT" >>"$LOG" 2>&1
    local rc=$?
    stop_qemu
    [ $rc = 0 ] && rec PASS "$name: console session" "all commands returned to prompt" \
                || rec FAIL "$name: console session" "rc=$rc (timeout / boot failure)"
    say "---- host-side / guest-output checks for $name"
}
h()     { printf 0x%x $(( $1 )); }
gout()  { cat "$OUT/$1.out" 2>/dev/null; }
# gexp <id> <step-name> <ERE> [<ERE>...] : every regex must match the command output
gexp() {
    local id=$1 step=$2; shift 2
    local f="$OUT/$id.out" re
    [ -f "$f" ] || { rec FAIL "$step" "no output for [$id]"; return 1; }
    for re in "$@"; do
        grep -Eq -- "$re" "$f" || { rec FAIL "$step" "[$id] missing /$re/: $(grep -Ev '^(RISC-V #)?$' "$f" | tail -2 | tr '\n' ' ')"; return 1; }
    done
    rec PASS "$step" "[$id] $(grep -Eo -- "$1" "$f" | head -1)"
}
# gnot <id> <step> <ERE> : regex must NOT match (and output must exist)
gnot() {
    local f="$OUT/$1.out"
    [ -f "$f" ] || { rec FAIL "$2" "no output for [$1]"; return 1; }
    grep -Eq -- "$3" "$f" && { rec FAIL "$2" "[$1] unexpected: $(grep -Eo -- "$3" "$f" | head -1)"; return 1; }
    rec PASS "$2" "[$1] $(grep -Ev '^(RISC-V #)?$' "$f" | sed -n 2p)"
}
gmd5()  { grep -Eo '==> [0-9a-f]{32}' "$OUT/$1.out" 2>/dev/null | awk '{print $2}'; }
hmd5()  { dd if="$1" bs=512 skip=$(($2)) count=$(($3)) status=none | md5sum | awk '{print $1}'; }
# hblk <step> <img> <blk> <cnt> <md5-id> : backing file blocks must equal the guest pattern md5
hblk() {
    local step=$1 img=$2 blk=$3 cnt=$4 g h; g=$(gmd5 "$5"); h=$(hmd5 "$img" "$blk" "$cnt")
    [ -n "$g" ] && [ "$g" = "$h" ] && rec PASS "$step" "img blk $blk+$cnt md5 $h" \
        || rec FAIL "$step" "img blk $blk+$cnt md5 host=$h guest=${g:-none}"
}
hff() {  # hff <step> <img> <blk> <cnt> : region must be all 0xff (erased)
    local n; n=$(dd if="$2" bs=512 skip=$(($3)) count=$(($4)) status=none | tr -d '\377' | wc -c)
    [ "$n" = 0 ] && rec PASS "$1" "img blk $3+$4 all 0xff" || rec FAIL "$1" "img blk $3+$4 has $n non-0xff bytes"
}
hfile() { # hfile <step> <file> <md5-id>
    local g h; g=$(gmd5 "$3"); h=$(md5sum < "$2" 2>/dev/null | awk '{print $1}')
    [ -n "$g" ] && [ "$g" = "$h" ] && rec PASS "$1" "$(stat -c %s "$2") bytes md5 $h" \
        || rec FAIL "$1" "host=$h guest=${g:-none}"
}
hcmd() { # hcmd <step> <cmd...> : host command must succeed
    local step=$1; shift; local o
    if o=$("$@" 2>&1); then rec PASS "$step" "$(echo "$o" | tail -1)"; else rec FAIL "$step" "$(echo "$o" | tail -2 | tr '\n' ' ')"; fi
    echo "$o" >> "$LOG"
}
same() { local n=$(( $1 )); echo "Total of $n byte\(s\) were the same"; }
# gbit <id> <step> <mask> <0|1> : read "md.l" output of the FTSDC010 STATUS reg, check bit(s)
gbit() {
    local v; v=$(grep -Eo '^f0e00028: [0-9a-f]{8}' "$OUT/$1.out" 2>/dev/null | awk '{print $2}')
    [ -z "$v" ] && { rec FAIL "$2" "[$1] no status value"; return 1; }
    local got=$(( (0x$v & $3) != 0 ))
    [ "$got" = "$4" ] && rec PASS "$2" "STATUS=0x$v" || rec FAIL "$2" "STATUS=0x$v mask $3 expected $4"
}
# hfsckfat <step> <img> : fsck.fat -n; the only tolerated issue is a stale FAT32 FSInfo
# free-cluster hint (U-Boot fs/fat never updates FSInfo — fs-layer limitation, not MMC)
hfsckfat() {
    local o rc; o=$(fsck.fat -n "$2" 2>&1); rc=$?; echo "$o" >> "$LOG"
    if [ $rc = 0 ]; then rec PASS "$1" "$(echo "$o" | tail -1)"; return; fi
    local rest; rest=$(echo "$o" | grep -Ev '^fsck.fat |Free cluster summary wrong|Auto-correcting|Leaving filesystem unchanged|^$|: [0-9]+ files, ')
    if [ -z "$rest" ] && echo "$o" | grep -q 'Free cluster summary wrong'; then
        rec PASS "$1" "clean except stale FSInfo free count (known U-Boot fatwrite behaviour)"
    else rec FAIL "$1" "$(echo "$o" | tail -3 | tr '\n' ' ')"; fi
}
extract() { dd if="$1" of="$2" bs=512 skip=$(($3)) count=$(($4)) status=none; }

# ================================================================ session 0: no card
C0=$WORK/s0.cmds
{
echo "st|10|md.l 0xf0e00028 1"
echo "rescan|30|mmc rescan"
echo "info|30|mmc info"
echo "fatls|30|fatls mmc 0:1"
} > "$C0"
run_session s0 none "$C0"
gbit st     "s0 STATUS.CARD_DETECT=1 (no card)" 0x800 1
gexp rescan "s0 mmc rescan: no card present" 'no card present'
gnot rescan "s0 no CMD timeouts w/o card"    'CMD[0-9]+ failed'
gexp info   "s0 mmc info: no card present"   'no card present'
gexp fatls  "s0 fatls fails cleanly"         "Couldn't find partition|Bad device"

# ================================================================ session 1: 128 MiB SDSC, MBR
I1=$WORK/s1_mbr128.img
say "== building $I1"
rm -f "$I1"; truncate -s 128M "$I1"
printf 'label: dos\nlabel-id: 0x4ae35001\nstart=2048, size=61440, type=6\nstart=63488, size=65536, type=83\n' | sfdisk -q "$I1"
sfdisk -d "$I1" > "$WORK/s1_mbr.before"
P1=$WORK/p1.tmp; P2=$WORK/p2.tmp
truncate -s $((61440*512)) "$P1"; mkfs.vfat -F 16 -n BOOT "$P1" >/dev/null
echo "hello from host fat" > "$WORK/hello.txt"; mcopy -i "$P1" "$WORK/hello.txt" ::HELLO.TXT
rm -f "$P2"; truncate -s $((65536*512)) "$P2"; mkfs.ext4 -q -F -O ^metadata_csum -L root "$P2"
echo "hello from host ext4" > "$WORK/hello4.txt"; debugfs -w -R "write $WORK/hello4.txt hello.txt" "$P2" >/dev/null 2>&1
dd if="$P1" of="$I1" bs=512 seek=2048 conv=notrunc status=none
dd if="$P2" of="$I1" bs=512 seek=63488 conv=notrunc status=none
rm -f "$P1" "$P2"
# raw area: blocks 0x20000..0x3ffff (64 MiB, unpartitioned)

# raw cases: id blk cnt   (non-overlapping, include odd counts and > 1 FIFO / > 1 page sizes)
RAW1=( "r1 0x20000 1" "r2 0x20010 2" "r3 0x20020 3" "r7 0x20030 7" "r127 0x20040 0x7f"
       "r255 0x20100 0xff" "r257 0x20200 0x101" "r8m 0x20400 0x4000" "r16m 0x24400 0x8000" )
C1=$WORK/s1.cmds
{
echo "st|10|md.l 0xf0e00028 1"
echo "rescan|20|mmc rescan"
echo "info|20|mmc info"
echo "part|20|mmc part"
echo "list|10|mmc list"
echo "dev0|10|mmc dev 0"
echo "dev1|10|mmc dev 1"
echo "devhw1|10|mmc dev 0 1"
echo "dev0b|10|mmc dev 0 0"
echo "rand|10|random $A $PATSZ 0x5eed"
echo "ffref|10|mw.b $C 0xff 0x100000"
for c in "${RAW1[@]}"; do set -- $c
    echo "$1_md5|10|md5sum $A $(printf 0x%x $(($3*512)))"
    echo "$1_w|240|mmc write $A $2 $3"
    echo "$1_clr|10|mw.b $B 0 $(printf 0x%x $(($3*512)))"
    echo "$1_r|240|mmc read $B $2 $3"
    echo "$1_cmp|30|cmp.b $A $B $(printf 0x%x $(($3*512)))"
done
# write a region, then overwrite it with different data (host must see the 2nd)
echo "ow_w0|20|mmc write $A 0x2e000 0x101"
echo "ow_w|20|mmc write $(h A+0x200000) 0x2e000 0x101"
echo "ow_md5|10|md5sum $(h A+0x200000) 0x20200"
echo "ow_r|20|mmc read $B 0x2e000 0x101"
echo "ow_cmp|10|cmp.b $(h A+0x200000) $B 0x20200"
# unaligned RAM buffers (driver uses 32-bit PIO on the buffer pointer)
echo "ua_w|20|mmc write $(h A+1) 0x2c400 0x11"
echo "ua_md5|10|md5sum $(h A+1) 0x2200"
echo "ua_r|20|mmc read $(h B+3) 0x2c400 0x11"
echo "ua_cmp|10|cmp.b $(h A+1) $(h B+3) 0x2200"
# last block of card, straddling end, past end
echo "last_w|20|mmc write $(h A+0x300000) 0x3ffff 1"
echo "last_md5|10|md5sum $(h A+0x300000) 0x200"
echo "last_r|20|mmc read $B 0x3ffff 1"
echo "last_cmp|10|cmp.b $(h A+0x300000) $B 0x200"
echo "past_w|20|mmc write $A 0x40000 1"
echo "strad_w|20|mmc write $A 0x3fffe 4"
echo "past_r|20|mmc read $B 0x40000 1"
# erase: fill 0x2d000+0x80, erase middle 0x2d010+0x20, verify edges kept
echo "er_fill|20|mmc write $A 0x2d000 0x80"
echo "er_md5a|10|md5sum $A 0x2000"
echo "er_md5b|10|md5sum $(h A+0x6000) 0xa000"
echo "erase|30|mmc erase 0x2d010 0x20"
echo "er_r|20|mmc read $B 0x2d000 0x80"
echo "er_cmpa|10|cmp.b $A $B 0x2000"
echo "er_cmpff|10|cmp.b $C $(h B+0x2000) 0x4000"
echo "er_cmpb|10|cmp.b $(h A+0x6000) $(h B+0x6000) 0xa000"
# odd single-block erase on SDSC (byte-addressed CMD32/33)
echo "er1_fill|20|mmc write $A 0x2d100 3"
echo "erase1|30|mmc erase 0x2d101 1"
echo "er1_r|20|mmc read $B 0x2d100 3"
echo "er1_cmpa|10|cmp.b $A $B 0x200"
echo "er1_cmpff|10|cmp.b $C $(h B+0x200) 0x200"
echo "er1_cmpb|10|cmp.b $(h A+0x400) $(h B+0x400) 0x200"
# FAT16 on p1
echo "fatls0|20|fatls mmc 0:1"
echo "fat_hello|20|fatload mmc 0:1 $B HELLO.TXT"
echo "fat_big_md5|10|md5sum $A 0x500000"
echo "fat_big_w|240|fatwrite mmc 0:1 $A BIG.BIN 0x500000"
echo "fat_odd_md5|10|md5sum $(h A+0x123) 0x12345"
echo "fat_odd_w|60|fatwrite mmc 0:1 $(h A+0x123) ODD.BIN 0x12345"
echo "fat_dir|20|fatmkdir mmc 0:1 /SUB"
echo "fat_sub_w|60|fatwrite mmc 0:1 $(h A+0x40000) /SUB/S.BIN 0x3001"
echo "fat_sub_md5|10|md5sum $(h A+0x40000) 0x3001"
echo "fatls1|20|fatls mmc 0:1"
echo "fat_big_l|240|fatload mmc 0:1 $B BIG.BIN"
echo "fat_big_cmp|30|cmp.b $A $B 0x500000"
echo "fat_odd_l|60|fatload mmc 0:1 $B ODD.BIN"
echo "fat_odd_cmp|10|cmp.b $(h A+0x123) $B 0x12345"
# ext4 on p2
echo "ext4ls0|20|ext4ls mmc 0:2 /"
echo "ext4_big_md5|10|md5sum $(h A+0x10) 0x300000"
echo "ext4_big_w|240|ext4write mmc 0:2 $(h A+0x10) /big.bin 0x300000"
echo "ext4_odd_md5|10|md5sum $(h A+0x777) 0x12345"
echo "ext4_odd_w|60|ext4write mmc 0:2 $(h A+0x777) /odd.bin 0x12345"
echo "ext4ls1|20|ext4ls mmc 0:2 /"
echo "ext4_big_l|240|ext4load mmc 0:2 $B /big.bin"
echo "ext4_big_cmp|30|cmp.b $(h A+0x10) $B 0x300000"
echo "ext4_odd_l|60|ext4load mmc 0:2 $B /odd.bin"
echo "ext4_odd_cmp|10|cmp.b $(h A+0x777) $B 0x12345"
# rescan, then reread through the whole stack again
echo "rescan2|20|mmc rescan"
echo "fat_big_l2|240|fatload mmc 0:1 $B BIG.BIN"
echo "fat_big_cmp2|30|cmp.b $A $B 0x500000"
echo "r8m_r2|240|mmc read $B 0x20400 0x4000"
echo "r8m_cmp2|30|cmp.b $A $B 0x800000"
} > "$C1"

run_session s1 "$I1" "$C1"
gbit st     "s1 STATUS.CARD_DETECT=0 (card)" 0x800 0
gbit st     "s1 STATUS.WRITE_PROT=0"         0x1000 0
gexp info   "s1 mmc info capacity"   'Capacity: 128 MiB'
gexp info   "s1 mmc info SDSC"       'High Capacity: No'
gexp info   "s1 mmc info bus width"  'Bus Width: 4-bit'
gexp info   "s1 mmc info speed"      'Bus Speed: 50000000' 'SD High Speed'
gexp part   "s1 mmc part (MBR)"      'Partition Type: DOS' '1[[:space:]]+2048[[:space:]]+61440' '2[[:space:]]+63488[[:space:]]+65536'
gexp list   "s1 mmc list"            'mmc@f0e00000: 0'
gexp dev0   "s1 mmc dev 0"           'mmc0 is current device'
gexp dev1   "s1 mmc dev 1 (no dev)"  'no mmc device at slot 1|Card did not respond|ERR|not found|Invalid'
gexp devhw1 "s1 mmc dev 0 1 (SD hwpart)" 'ERROR|failed|not support'
gexp dev0b  "s1 mmc dev 0 0 back"    'switch to partitions #0, OK' 'mmc0 is current device'
for c in "${RAW1[@]}"; do set -- $c
    gexp "$1_w"   "s1 raw write $3@$2"  "$(($3)) blocks written: OK"
    gexp "$1_cmp" "s1 raw readback $3@$2" "$(same $(($3*512)))"
    hblk "s1 host verify $3@$2" "$I1" "$2" "$3" "$1_md5"
done
gexp ow_cmp  "s1 overwrite readback"         "$(same 0x20200)"
hblk "s1 host verify overwrite" "$I1" 0x2e000 0x101 ow_md5
gexp ua_cmp  "s1 unaligned buf w/r"          "$(same 0x2200)"
hblk "s1 host verify unaligned" "$I1" 0x2c400 0x11 ua_md5
gexp last_w  "s1 last block write"           '1 blocks written: OK'
gexp last_cmp "s1 last block readback"       "$(same 0x200)"
hblk "s1 host verify last block" "$I1" 0x3ffff 1 last_md5
gnot past_w  "s1 write past end rejected"    'blocks written: OK'
gnot strad_w "s1 write straddling end rejected" '4 blocks written: OK'
gnot past_r  "s1 read past end rejected"     'blocks read: OK'
gexp erase   "s1 mmc erase 32 blk"           '32 blocks erased: OK'
gexp er_cmpa "s1 erase keeps head"           "$(same 0x2000)"
gexp er_cmpff "s1 erased range = 0xff"       "$(same 0x4000)"
gexp er_cmpb "s1 erase keeps tail"           "$(same 0xa000)"
hblk "s1 host erase head intact" "$I1" 0x2d000 0x10 er_md5a
hff  "s1 host erased range"      "$I1" 0x2d010 0x20
hblk "s1 host erase tail intact" "$I1" 0x2d030 0x50 er_md5b
gexp erase1  "s1 mmc erase 1 blk"            '1 blocks erased: OK'
gexp er1_cmpa "s1 1-blk erase keeps prev"    "$(same 0x200)"
gexp er1_cmpff "s1 1-blk erased = 0xff"      "$(same 0x200)"
gexp er1_cmpb "s1 1-blk erase keeps next"    "$(same 0x200)"
hff  "s1 host 1-blk erased"      "$I1" 0x2d101 1
gexp fat_hello "s1 fatload host file"        '20 bytes read'
gexp fat_big_w "s1 fatwrite 5MiB"            '5242880 bytes written'
gexp fat_odd_w "s1 fatwrite 0x12345 B"       '74565 bytes written'
gexp fat_sub_w "s1 fatwrite into subdir"     '12289 bytes written'
gexp fatls1 "s1 fatls lists new files"       'BIG.BIN' 'ODD.BIN' 'HELLO.TXT' 'SUB/'
gexp fat_big_cmp "s1 fatload BIG.BIN == src" "$(same 0x500000)"
gexp fat_odd_cmp "s1 fatload ODD.BIN == src" "$(same 0x12345)"
gexp ext4ls0 "s1 ext4ls host file"           'hello.txt'
gexp ext4_big_w "s1 ext4write 3MiB"          '3145728 bytes written'
gexp ext4_odd_w "s1 ext4write 0x12345 B"     '74565 bytes written'
gexp ext4_big_cmp "s1 ext4load big == src"   "$(same 0x300000)"
gexp ext4_odd_cmp "s1 ext4load odd == src"   "$(same 0x12345)"
gexp fat_big_cmp2 "s1 after rescan fatload"  "$(same 0x500000)"
gexp r8m_cmp2 "s1 after rescan raw 8MiB"     "$(same 0x800000)"
# host-side filesystem checks
sfdisk -d "$I1" > "$WORK/s1_mbr.after"
hcmd "s1 host MBR unchanged" cmp "$WORK/s1_mbr.before" "$WORK/s1_mbr.after"
extract "$I1" "$WORK/p1.tmp" 2048 61440
extract "$I1" "$WORK/p2.tmp" 63488 65536
hfsckfat "s1 host fsck.fat p1" "$WORK/p1.tmp"
rm -rf "$WORK/x"; mkdir -p "$WORK/x"
mcopy -n -i "$WORK/p1.tmp" ::BIG.BIN ::ODD.BIN ::HELLO.TXT ::SUB/S.BIN "$WORK/x/" 2>>"$LOG"
hfile "s1 host FAT BIG.BIN"  "$WORK/x/BIG.BIN" fat_big_md5
hfile "s1 host FAT ODD.BIN"  "$WORK/x/ODD.BIN" fat_odd_md5
hfile "s1 host FAT SUB/S.BIN" "$WORK/x/S.BIN"  fat_sub_md5
hcmd "s1 host FAT HELLO.TXT intact" cmp "$WORK/hello.txt" "$WORK/x/HELLO.TXT"
hcmd "s1 host e2fsck p2"     e2fsck -fn "$WORK/p2.tmp"
debugfs -R "dump /big.bin $WORK/x/big.bin" "$WORK/p2.tmp" >/dev/null 2>&1
debugfs -R "dump /odd.bin $WORK/x/odd.bin" "$WORK/p2.tmp" >/dev/null 2>&1
debugfs -R "dump /hello.txt $WORK/x/hello4.txt" "$WORK/p2.tmp" >/dev/null 2>&1
hfile "s1 host ext4 big.bin" "$WORK/x/big.bin" ext4_big_md5
hfile "s1 host ext4 odd.bin" "$WORK/x/odd.bin" ext4_odd_md5
hcmd "s1 host ext4 hello.txt intact" cmp "$WORK/hello4.txt" "$WORK/x/hello4.txt"
rm -f "$WORK/p1.tmp" "$WORK/p2.tmp"

# ================================================================ session 2: 2 GiB SDSC edge, gpt write
I2=$WORK/s2_sdsc2g.img
rm -f "$I2"; truncate -s 2G "$I2"
LASTB2=$(( 2*1024*1024*2 - 1 ))   # 0x3fffff
C2=$WORK/s2.cmds
{
echo "info|20|mmc info"
echo "rand|10|random $A 0x200000 0xa11ce"
echo "parts|10|setenv parts 'name=alpha,start=1MiB,size=256MiB;name=beta,size=512MiB;name=gamma,size=-'"
echo "gptw|60|gpt write mmc 0 \"\${parts}\""
echo "gptv|60|gpt verify mmc 0 \"\${parts}\""
echo "plist|20|part list mmc 0"
echo "hi_md5|10|md5sum $A 0x100000"
echo "hi_w|60|mmc write $A 0x3fe000 0x800"
echo "hi_r|60|mmc read $B 0x3fe000 0x800"
echo "hi_cmp|10|cmp.b $A $B 0x100000"
echo "hi1_md5|10|md5sum $(h A+0x100000) 0x200"
echo "hi1_w|20|mmc write $(h A+0x100000) 0x3fffbf 1"
echo "hi1_r|20|mmc read $B 0x3fffbf 1"
echo "hi1_cmp|10|cmp.b $(h A+0x100000) $B 0x200"
echo "last_r|20|mmc read $B $(printf 0x%x $LASTB2) 1"
echo "last_md|10|md.b $B 0x10"
} > "$C2"
run_session s2 "$I2" "$C2"
gexp info "s2 mmc info capacity 2GiB"     'Capacity: 2 GiB'
gexp info "s2 mmc info SDSC"              'High Capacity: No'
gexp gptw "s2 gpt write"                  'success'
gexp gptv "s2 gpt verify"                 'success|OK'
gexp plist "s2 part list GPT"             'alpha' 'beta' 'gamma' 'EFI'
gexp hi_cmp "s2 1MiB raw @ ~2GiB"         "$(same 0x100000)"
hblk "s2 host verify 1MiB @0x3fe000" "$I2" 0x3fe000 0x800 hi_md5
gexp hi1_cmp "s2 raw blk 0x3fffbf"        "$(same 0x200)"
hblk "s2 host verify blk 0x3fffbf" "$I2" 0x3fffbf 1 hi1_md5
gexp last_md "s2 read backup GPT hdr @last LBA" 'EFI PART'
hcmd "s2 host sgdisk -v (GPT written by U-Boot)" sgdisk -v "$I2"
sgdisk -p "$I2" >> "$WORK/s2.sgdisk" 2>&1; cat "$WORK/s2.sgdisk" >> "$LOG"
if grep -q alpha "$WORK/s2.sgdisk" && grep -q beta "$WORK/s2.sgdisk" && grep -Eq '^ +1 +2048 +526335 ' "$WORK/s2.sgdisk"; then
    rec PASS "s2 host GPT layout" "alpha@2048..526335, beta, gamma"
else rec FAIL "s2 host GPT layout" "$(grep -E '^ +[0-9]' "$WORK/s2.sgdisk" | tr -s ' ' | tr '\n' ';')"; fi

# ================================================================ session 3: 8 GiB SDHC, host GPT
I3=$WORK/s3_sdhc8g.img
rm -f "$I3"; truncate -s 8G "$I3"
S3P1=12582912   # 6 GiB  (byte offset > 4 GiB: catches byte-vs-block addressing)
S3P2=13631488   # 6.5 GiB
SZP=524288      # 256 MiB
sgdisk -n 1:$S3P1:+256M -t 1:0700 -c 1:bootfat -n 2:$S3P2:+256M -t 2:8300 -c 2:rootfs "$I3" >>"$LOG" 2>&1 || die "sgdisk failed"
truncate -s $((SZP*512)) "$WORK/p1.tmp"; mkfs.vfat -F 32 -n HIFAT "$WORK/p1.tmp" >/dev/null
mcopy -i "$WORK/p1.tmp" "$WORK/hello.txt" ::HELLO.TXT
rm -f "$WORK/p2.tmp"; truncate -s $((SZP*512)) "$WORK/p2.tmp"; mkfs.ext4 -q -F -O ^metadata_csum -L hiext4 "$WORK/p2.tmp"
dd if="$WORK/p1.tmp" of="$I3" bs=1M seek=$((S3P1/2048)) conv=notrunc,sparse status=none
dd if="$WORK/p2.tmp" of="$I3" bs=1M seek=$((S3P2/2048)) conv=notrunc,sparse status=none
rm -f "$WORK/p1.tmp" "$WORK/p2.tmp"
C3=$WORK/s3.cmds
{
echo "info|20|mmc info"
echo "plist|20|part list mmc 0"
echo "last_r|20|mmc read $B 0xffffff 1"
echo "last_md|10|md.b $B 0x10"
echo "rand|10|random $A 0x800000 0xbeef"
echo "hi_md5|10|md5sum $A 0x800000"
echo "hi_w|240|mmc write $A 0xf00000 0x4000"
echo "hi_r|240|mmc read $B 0xf00000 0x4000"
echo "hi_cmp|30|cmp.b $A $B 0x800000"
echo "o_md5|10|md5sum $(h A+0x1000) 0xa00"
echo "o_w|20|mmc write $(h A+0x1000) 0xf80001 5"
echo "o_r|20|mmc read $B 0xf80001 5"
echo "o_cmp|10|cmp.b $(h A+0x1000) $B 0xa00"
echo "ffref|10|mw.b $C 0xff 0x10000"
echo "er_fill|20|mmc write $A 0xf90000 0x40"
echo "er_md5a|10|md5sum $A 0x1000"
echo "er_md5b|10|md5sum $(h A+0x5000) 0x3000"
echo "erase|30|mmc erase 0xf90008 0x20"
echo "er_r|20|mmc read $B 0xf90000 0x40"
echo "er_cmpa|10|cmp.b $A $B 0x1000"
echo "er_cmpff|10|cmp.b $C $(h B+0x1000) 0x4000"
echo "er_cmpb|10|cmp.b $(h A+0x5000) $(h B+0x5000) 0x3000"
echo "past_w|20|mmc write $A 0x1000000 1"
echo "fat_hello|20|fatload mmc 0:1 $B HELLO.TXT"
echo "fat_w|240|fatwrite mmc 0:1 $A HI.BIN 0x400000"
echo "fat_md5|10|md5sum $A 0x400000"
echo "fat_l|240|fatload mmc 0:1 $B HI.BIN"
echo "fat_cmp|30|cmp.b $A $B 0x400000"
echo "ext4_w|240|ext4write mmc 0:2 $(h A+0x5) /hi.bin 0x2abcd"
echo "ext4_md5|10|md5sum $(h A+0x5) 0x2abcd"
echo "ext4_l|240|ext4load mmc 0:2 $B /hi.bin"
echo "ext4_cmp|30|cmp.b $(h A+0x5) $B 0x2abcd"
} > "$C3"
run_session s3 "$I3" "$C3"
gexp info "s3 mmc info capacity 8GiB"   'Capacity: 8 GiB'
gexp info "s3 mmc info SDHC"            'High Capacity: Yes'
gexp info "s3 mmc info bus width"       'Bus Width: 4-bit'
gexp plist "s3 part list host GPT"      'bootfat' 'rootfs' "0x0*$(printf %x $S3P1)"
gexp last_md "s3 read backup GPT @LBA 0xffffff" 'EFI PART'
gexp hi_cmp "s3 8MiB raw @7.5GiB"       "$(same 0x800000)"
hblk "s3 host verify 8MiB @0xf00000" "$I3" 0xf00000 0x4000 hi_md5
gexp o_cmp "s3 odd 5 blk @0xf80001"     "$(same 0xa00)"
hblk "s3 host verify 5 blk @0xf80001" "$I3" 0xf80001 5 o_md5
gexp erase "s3 mmc erase (SDHC)"        '32 blocks erased: OK'
gexp er_cmpa "s3 erase keeps head"      "$(same 0x1000)"
gexp er_cmpff "s3 erased = 0xff"        "$(same 0x4000)"
gexp er_cmpb "s3 erase keeps tail"      "$(same 0x3000)"
hblk "s3 host erase head intact" "$I3" 0xf90000 8 er_md5a
hff  "s3 host erased range"      "$I3" 0xf90008 0x20
hblk "s3 host erase tail intact" "$I3" 0xf90028 0x18 er_md5b
gnot past_w "s3 write past end rejected" 'blocks written: OK'
gexp fat_hello "s3 FAT32@6GiB fatload"  '20 bytes read'
gexp fat_w "s3 FAT32@6GiB fatwrite 4MiB" '4194304 bytes written'
gexp fat_cmp "s3 FAT32 readback"         "$(same 0x400000)"
gexp ext4_w "s3 ext4@6.5GiB ext4write"   "$((0x2abcd)) bytes written"
gexp ext4_cmp "s3 ext4 readback"         "$(same 0x2abcd)"
hcmd "s3 host sgdisk -v" sgdisk -v "$I3"
extract "$I3" "$WORK/p1.tmp" $S3P1 $SZP
extract "$I3" "$WORK/p2.tmp" $S3P2 $SZP
hfsckfat "s3 host fsck.fat p1" "$WORK/p1.tmp"
rm -f "$WORK/x/HI.BIN"; mcopy -n -i "$WORK/p1.tmp" ::HI.BIN "$WORK/x/" 2>>"$LOG"
hfile "s3 host FAT32 HI.BIN" "$WORK/x/HI.BIN" fat_md5
hcmd "s3 host e2fsck p2" e2fsck -fn "$WORK/p2.tmp"
rm -f "$WORK/x/hi.bin"; debugfs -R "dump /hi.bin $WORK/x/hi.bin" "$WORK/p2.tmp" >/dev/null 2>&1
hfile "s3 host ext4 hi.bin" "$WORK/x/hi.bin" ext4_md5
rm -f "$WORK/p1.tmp" "$WORK/p2.tmp"

[ "$KEEP" = 1 ] || rm -f "$I2" "$I3"

# ================================================================ summary
say ""
say "================ SUMMARY  ($(date '+%F %T'))  U-Boot=$UBOOT"
for r in "${RESULTS[@]}"; do say "$r"; done
say "PASS=$NPASS FAIL=$NFAIL"
say "log: $LOG"
[ "$NFAIL" = 0 ]
