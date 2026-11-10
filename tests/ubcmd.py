#!/usr/bin/env python3
"""非互動送 U-Boot 指令到 ae350.sh 開的 telnet console。
用法: ubcmd.py <port> <timeout> "cmd1" "cmd2" ...
"""
import socket, sys, time

port = int(sys.argv[1])
budget = float(sys.argv[2])
cmds = sys.argv[3:]

s = socket.create_connection(("127.0.0.1", port), timeout=10)
s.settimeout(0.5)
buf = b""
stopped = False
queue = list(cmds)
deadline = time.time() + budget
next_send = 0.0

while time.time() < deadline:
    try:
        d = s.recv(4096)
        if not d:
            break
        buf += d
    except socket.timeout:
        pass

    # 看到倒數就敲鍵中斷 autoboot
    if not stopped and b"Hit any key" in buf:
        s.sendall(b"\r")
        stopped = True
        next_send = time.time() + 1.0
        continue

    if stopped and queue and time.time() >= next_send and buf.rstrip().endswith(b"#"):
        s.sendall(queue.pop(0).encode() + b"\r")
        next_send = time.time() + 0.3
        if not queue:
            deadline = min(deadline, time.time() + 6)

s.close()
# 去掉 telnet IAC negotiation 與 ANSI escape
out = bytearray()
i = 0
while i < len(buf):
    if buf[i] == 0xFF and i + 2 < len(buf):
        i += 3
        continue
    out.append(buf[i])
    i += 1
txt = out.decode("utf-8", "replace")
import re
txt = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", txt)
sys.stdout.write(txt)
