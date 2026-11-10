#!/usr/bin/env python3
"""SPI NOR (ATCSPI200 + MX25L1606E) end-to-end test for U-Boot on AE350 QEMU.

Called by test_spi.sh.  Usage:
    test_spi.py <ae350.sh> <port> <spi.img> <log file> [seed]

Boot 1 exercises sf probe/read/erase/write/update/test + saveenv, then QEMU is
stopped and the backing image is checked on the host; boot 2 checks that the
environment and all written data persisted.
"""
import os, random, re, socket, subprocess, sys, time, zlib

AE350, PORT, IMG, LOG = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
SEED = int(sys.argv[5]) if len(sys.argv) > 5 else 0x5350

FLASH = 2 << 20
ENV_OFF, ENV_SIZE = 0x140000, 0x2000
SFTEST_OFF, SFTEST_LEN = 0x40000, 0x20000
PROMPT = b"RISC-V # "
RAM, RAM2 = 0x1000000, 0x1400000          # flash mirror / read-back buffer

results = []
logf = open(LOG, "w")


def log(s):
    logf.write(s)
    logf.flush()


def record(name, ok, detail=""):
    results.append((name, ok, detail))
    line = "%-4s %s%s" % ("PASS" if ok else "FAIL", name,
                          ("  (" + detail + ")") if detail else "")
    print(line, flush=True)
    log("\n### " + line + "\n")


class Console:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.s.settimeout(0.2)
        self.buf = b""

    def _recv(self):
        try:
            d = self.s.recv(65536)
        except socket.timeout:
            return False
        if not d:
            raise EOFError("console closed")
        # drop telnet IAC sequences (QEMU only negotiates at connect)
        out, i = bytearray(), 0
        while i < len(d):
            if d[i] == 0xFF and i + 2 < len(d) and d[i + 1] != 0xFF:
                i += 3
                continue
            out.append(d[i])
            i += 1
        d = bytes(out)
        self.buf += d
        log(d.decode("utf-8", "replace"))
        return True

    def wait_for(self, pat, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if pat in self.buf:
                return True
            self._recv()
        return pat in self.buf

    def boot(self, timeout=60):
        if not self.wait_for(b"Hit any key", timeout):
            return None
        self.s.sendall(b"\r")
        self.wait_for(PROMPT, 10)
        text = self.buf.decode("utf-8", "replace")
        self.buf = b""
        return text

    def run(self, cmd, timeout=120):
        self.buf = b""
        self.s.sendall(cmd.encode() + b"\r")
        end = time.time() + timeout
        while time.time() < end:
            self._recv()
            # prompt after the echoed command line = command finished
            nl = self.buf.find(b"\n")
            if nl >= 0 and self.buf.endswith(PROMPT) and len(self.buf) > nl:
                break
        out = self.buf.decode("utf-8", "replace")
        out = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", out)
        body = out.split("\n", 1)[1] if "\n" in out else ""
        if body.endswith(PROMPT.decode()):
            body = body[:-len(PROMPT)]
        return body

    def close(self):
        self.s.close()


def start_qemu():
    env = dict(os.environ, SPI=IMG)
    r = subprocess.run([AE350, "start", str(PORT)], env=env,
                       capture_output=True, text=True)
    log("\n===== ae350.sh start %d =====\n%s%s\n" % (PORT, r.stdout, r.stderr))
    if r.returncode:
        print(r.stdout + r.stderr)
        sys.exit("cannot start QEMU")
    time.sleep(0.5)
    return Console(PORT)


def stop_qemu(con):
    con.close()
    pidf = os.path.join(os.path.dirname(AE350), "run", "qemu-%d.pid" % PORT)
    pid = int(open(pidf).read()) if os.path.exists(pidf) else None
    subprocess.run([AE350, "stop", str(PORT)], capture_output=True)
    # wait for QEMU to exit so the backing image is flushed
    for _ in range(100):
        if pid is None or not os.path.exists("/proc/%d" % pid):
            break
        time.sleep(0.1)
    log("\n===== QEMU on port %d stopped =====\n" % PORT)


def crc_of(out):
    m = re.search(r"==>\s*([0-9a-fA-F]{8})", out)
    return int(m.group(1), 16) if m else None


def check_crc(con, name, off, length, expect_bytes):
    out = con.run("sf read %#x %#x %#x" % (RAM2, off, length))
    ok_rd = "Read: OK" in out
    out2 = con.run("crc32 %#x %#x" % (RAM2, length))
    got, exp = crc_of(out2), zlib.crc32(expect_bytes)
    record(name, ok_rd and got == exp,
           "crc %s expect %08x" % ("%08x" % got if got is not None else "?", exp))


def check_cmp(con, name, a, b, n):
    out = con.run("cmp.b %#x %#x %#x" % (a, b, n))
    record(name, ("Total of %d byte(s) were the same" % n) in out,
           out.strip().splitlines()[-1] if out.strip() else "no output")


# ---------------------------------------------------------------- image
rng = random.Random(SEED)
orig = bytearray(rng.randbytes(FLASH))
orig[ENV_OFF:ENV_OFF + ENV_SIZE] = b"\xff" * ENV_SIZE      # blank env
with open(IMG, "wb") as f:
    f.write(orig)
marker = "spi%08x" % rng.getrandbits(32)
exp = bytearray(orig)                   # expected flash after boot 1

# ---------------------------------------------------------------- boot 1
con = start_qemu()
bootlog = con.boot()
record("boot1: U-Boot prompt reached", bootlog is not None)
if bootlog is None:
    stop_qemu(con)
    sys.exit(1)
record("boot1: env loaded via SPI flash (MX25L1606E detected)",
       re.search(r"Loading Environment from SPIFlash\.\.\.\s*SF: Detected mx25l1606e", bootlog) is not None)

out = con.run("sf probe")
record("sf probe", re.search(r"SF: Detected mx25l1606e with page size 256 Bytes, "
                             r"erase size 4 KiB, total 2 MiB", out) is not None)

# reads: whole chip (many 512 B controller chunks, crosses every 64 KiB
# boundary), unaligned, one byte at the end, and a short read whose second
# 512 B chunk starts in the next 64 KiB block
out = con.run("sf read %#x 0 %#x" % (RAM, FLASH), timeout=300)
crc = crc_of(con.run("crc32 %#x %#x" % (RAM, FLASH)))
record("sf read whole chip 2 MiB @0x0", "Read: OK" in out and crc == zlib.crc32(orig),
       "crc %s expect %08x" % ("%08x" % crc if crc is not None else "?", zlib.crc32(orig)))
check_crc(con, "sf read unaligned 0x1001 B @0x12345", 0x12345, 0x1001,
          orig[0x12345:0x12345 + 0x1001])
check_crc(con, "sf read 1 B @0x1fffff (last byte)", 0x1fffff, 1, orig[0x1fffff:])
check_crc(con, "sf read 0x400 B @0xfe80 (2nd chunk crosses 64K)", 0xfe80, 0x400,
          orig[0xfe80:0xfe80 + 0x400])
check_crc(con, "sf read 0x3 B @0x7ffff (crosses 512K)", 0x7ffff, 3, orig[0x7ffff:0x80002])

# erase one 64 KiB block (16 x 4K sectors)
out = con.run("sf erase 0x10000 0x10000")
record("sf erase 0x10000 +0x10000", "Erased: OK" in out)
exp[0x10000:0x20000] = b"\xff" * 0x10000
check_crc(con, "erased block reads back as 0xFF", 0x10000, 0x10000, exp[0x10000:0x20000])

# erase of an unaligned range must be rejected by the spi-nor core
out = con.run("sf erase 0x20001 0x1000")
record("sf erase unaligned offset rejected", "Erased: OK" not in out,
       out.strip().splitlines()[-1] if out.strip() else "")

# writes: unaligned, multi-page (> FIFO, > page), single byte, page-tail
writes = [(0x80000, 0x10003, 0x1234),   # unaligned start, 19 pages
          (0x90000, 0x1f000, 0x1),      # single byte
          (0xa0000, 0x1fff0, 0x10),     # last 16 bytes of the block
          (0xb0000, 0x18000, 0x100),    # exactly one aligned page
          (0xc0000, 0x1a0fe, 0x203)]    # starts 2 B before a page boundary
for src, off, n in writes:
    out = con.run("sf write %#x %#x %#x" % (RAM + src, off, n))
    record("sf write %#x B @%#x" % (n, off), "Written: OK" in out)
    exp[off:off + n] = orig[src:src + n]
    con.run("sf read %#x %#x %#x" % (RAM2, off, n))
    check_cmp(con, "  read-back cmp.b %#x B @%#x" % (n, off), RAM + src, RAM2, n)

# update: unaligned offset/length, partial sectors at both ends
uoff, ulen, usrc = 0x30100, 0x5123, 0x100000
out = con.run("sf update %#x %#x %#x" % (RAM + usrc, uoff, ulen))
record("sf update %#x B @%#x" % (ulen, uoff),
       re.search(r"%d bytes written, 0 bytes skipped" % ulen, out) is not None,
       out.strip().splitlines()[-1] if out.strip() else "")
exp[uoff:uoff + ulen] = orig[usrc:usrc + ulen]
con.run("sf read %#x %#x %#x" % (RAM2, uoff, ulen))
check_cmp(con, "  read-back cmp.b after update", RAM + usrc, RAM2, ulen)
check_crc(con, "  update preserved sector head/tail", 0x30000, 0x6000, exp[0x30000:0x36000])
out = con.run("sf update %#x %#x %#x" % (RAM + usrc, uoff, ulen))
record("sf update again -> all skipped",
       re.search(r"0 bytes written, %d bytes skipped" % ulen, out) is not None,
       out.strip().splitlines()[-1] if out.strip() else "")

# built-in test (erase/verify blank/write/verify) on 128 KiB
out = con.run("sf test %#x %#x" % (SFTEST_OFF, SFTEST_LEN), timeout=300)
record("sf test %#x %#x" % (SFTEST_OFF, SFTEST_LEN), "Test passed" in out,
       out.strip().splitlines()[-1] if out.strip() else "")

# environment
con.run("setenv spi_marker " + marker)
out = con.run("saveenv")
record("saveenv", re.search(r"Saving Environment to SPIFlash.*OK", out, re.S) is not None)
stop_qemu(con)

# ---------------------------------------------------------------- host side
img = open(IMG, "rb").read()
mask = lambda b: b[:SFTEST_OFF] + b[SFTEST_OFF + SFTEST_LEN:ENV_OFF] + b[ENV_OFF + ENV_SIZE:]
bad = [i for i in range(0, FLASH, 0x1000)
       if not (SFTEST_OFF <= i < SFTEST_OFF + SFTEST_LEN or ENV_OFF <= i < ENV_OFF + ENV_SIZE)
       and img[i:i + 0x1000] != exp[i:i + 0x1000]]
record("host: backing image == expected (outside env/sf-test areas)",
       len(img) == FLASH and mask(img) == mask(bytes(exp)),
       "mismatching 4K sectors: " + ",".join("%#x" % i for i in bad[:8]) if bad else "")
env = img[ENV_OFF:ENV_OFF + ENV_SIZE]
crc_ok = int.from_bytes(env[:4], "little") == zlib.crc32(env[4:])
record("host: env sector has valid CRC and spi_marker",
       crc_ok and ("spi_marker=" + marker).encode() in env)

# ---------------------------------------------------------------- boot 2
con = start_qemu()
bootlog = con.boot()
record("boot2: U-Boot prompt reached", bootlog is not None)
if bootlog is not None:
    record("boot2: no 'bad CRC' (env read from flash)",
           "Loading Environment from SPIFlash" in bootlog and "bad CRC" not in bootlog)
    out = con.run("printenv spi_marker")
    record("boot2: printenv spi_marker persisted", ("spi_marker=" + marker) in out)
    con.run("sf probe")
    out = con.run("sf read %#x 0 %#x" % (RAM, FLASH), timeout=300)
    crc = crc_of(con.run("crc32 %#x %#x" % (RAM, FLASH)))
    record("boot2: whole-chip read matches backing image",
           "Read: OK" in out and crc == zlib.crc32(img),
           "crc %s expect %08x" % ("%08x" % crc if crc is not None else "?", zlib.crc32(img)))
stop_qemu(con)

# ---------------------------------------------------------------- summary
npass = sum(1 for r in results if r[1])
summary = "\n==== SUMMARY: %d/%d PASS ====\n" % (npass, len(results))
summary += "".join("%-4s %s%s\n" % ("PASS" if ok else "FAIL", n,
                                    ("  (" + d + ")") if d else "")
                   for n, ok, d in results)
print(summary)
log("\n" + summary)
logf.close()
sys.exit(0 if npass == len(results) else 1)
