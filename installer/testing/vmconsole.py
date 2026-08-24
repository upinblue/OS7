#!/usr/bin/env python3
"""
Driving a QEMU guest over its serial console — the shared half of the Phase 0
spike harnesses (`run-s3.py`, and whatever S1/S4 need).

docs/HANDOFF.md §5 says not to drive a boot over QEMU's serial console. That is
right about *typing*, and everything here works within it: read freely, type one
character at a time, and re-send a step whose acknowledgement never arrives
rather than assuming it landed. The three things that make it work at all are
documented at the point where each one bites (docs/BUILD-NOTES.md #16).
"""
import os
import re
import shutil
import subprocess
import threading
import time


# Typing rate. 25 ms/char is slow enough that the console keeps up and fast
# enough that a 50-character command is over in about a second.
CHAR_DELAY = 0.025
LINE_PAUSE = 0.30


# ---------------------------------------------------------------------------
# Just enough terminal to keep a real shell alive.
#
# There is nothing on the far end of QEMU's serial line but this script, so
# every terminal query the guest sends goes unanswered. agetty and login shrug
# that off. PowerShell does not: with no reply to the DSR and OSC probes
# PSReadLine makes at startup, the session ends within a second of the prompt
# appearing and agetty respawns a fresh `login:` before anything can be typed.
# Answering the handful of queries below is what keeps it alive — observed, not
# traced into PSReadLine.
#
# Recorded rather than worked around, because OS/7 ships PowerShell as its
# interactive shell and SETUP-PLAN §7 wants `os7-setup --serial` on ttyAMA0.
QUERY_RX = re.compile(
    rb"\x1b\[6n"                              # DSR — cursor position
    rb"|\x1b\[5n"                              # DSR — device status
    rb"|\x1b\[[>=]?0?c"                        # DA1 / DA2 — device attributes
    rb"|\x1b\](1[01]);\?(?:\x1b\\|\x07)"      # OSC 10/11 — fg/bg colour
    rb"|\x1bP\+q([0-9A-Fa-f;]+)\x1b\\"        # XTGETTCAP — termcap strings
)


def terminal_reply(m):
    q = m.group(0)
    if q.endswith(b"6n"):
        return b"\x1b[24;80R"
    if q.endswith(b"5n"):
        return b"\x1b[0n"
    if q.endswith(b"c"):
        return b"\x1b[?1;2c"
    if m.group(1):                              # OSC 10/11
        rgb = b"ffff/ffff/ffff" if m.group(1) == b"10" else b"0000/0000/0000"
        return b"\x1b]" + m.group(1) + b";rgb:" + rgb + b"\x1b\\"
    if m.group(2):                              # XTGETTCAP: answer "unsupported"
        return b"\x1bP0+r" + m.group(2) + b"\x1b\\"
    return None


class Console:
    """Minimal expect over QEMU's serial stdio."""

    def __init__(self, args, logpath):
        self.log = open(logpath, "wb", buffering=0)
        self.buf = bytearray()
        self.scan = bytearray()
        self.answering = False
        self.lock = threading.Lock()
        self.wlock = threading.Lock()
        self.replies = 0
        self.proc = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, bufsize=0,
        )
        self.reader = threading.Thread(target=self._pump, daemon=True)
        self.reader.start()

    def _write(self, data):
        with self.wlock:
            try:
                self.proc.stdin.write(data)
                self.proc.stdin.flush()
            except (BrokenPipeError, ValueError):
                pass

    def _answer_queries(self, chunk):
        if not self.answering:
            return
        self.scan += chunk
        while True:
            m = QUERY_RX.search(self.scan)
            if not m:
                break
            reply = terminal_reply(m)
            if reply:
                self._write(reply)
                self.replies += 1
            del self.scan[:m.end()]
        if len(self.scan) > 4096:
            del self.scan[:-64]

    def _pump(self):
        while True:
            chunk = self.proc.stdout.read(1)
            if not chunk:
                return
            self.log.write(chunk)
            self._answer_queries(chunk)
            with self.lock:
                self.buf += chunk

    def text(self):
        with self.lock:
            return self.buf.decode("utf-8", "replace")

    def drop(self):
        with self.lock:
            self.buf.clear()

    def expect(self, patterns, timeout, label=""):
        """Wait for any of `patterns` (regex). Returns the index that matched."""
        if isinstance(patterns, str):
            patterns = [patterns]
        rx = [re.compile(p, re.I) for p in patterns]
        deadline = time.time() + timeout
        last = 0.0
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise SystemExit(f"QEMU exited while waiting for {label or patterns}")
            t = self.text()
            for i, r in enumerate(rx):
                if r.search(t):
                    return i
            now = time.time()
            if now - last > 30:
                last = now
                print(f"    … still waiting for {label or patterns[0]} "
                      f"({int(deadline - now)}s left)", flush=True)
            time.sleep(0.2)
        tail = self.text()[-1500:]
        raise SystemExit(
            f"TIMEOUT waiting for {label or patterns}\n--- last output ---\n{tail}"
        )

    def send(self, text, enter=True):
        # CR, not LF. A getty in canonical mode accepts either, but PSReadLine
        # puts the terminal in raw mode and reads keys: LF is not the Enter key,
        # so every "command" silently accumulated into one line that was never
        # submitted — while the echo of it still matched whatever was expected.
        data = (text + ("\r" if enter else "")).encode()
        for b in data:
            self._write(bytes([b]))
            time.sleep(CHAR_DELAY)
        time.sleep(LINE_PAUSE)

    def settle(self, quiet=2.0, timeout=60):
        """Wait until the console has been silent for `quiet` seconds. Typing
        into a shell that is still painting its prompt loses the first
        characters, and the loss is invisible until the command never runs."""
        deadline = time.time() + timeout
        last_len = -1
        quiet_since = time.time()
        while time.time() < deadline:
            n = len(self.buf)
            if n != last_len:
                last_len = n
                quiet_since = time.time()
            elif time.time() - quiet_since >= quiet:
                return
            time.sleep(0.2)

    def close(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()
        self.log.close()


def run(*args, **kw):
    return subprocess.run(args, check=True, **kw)


def qemu_prefix():
    p = subprocess.run(["brew", "--prefix", "qemu"], capture_output=True, text=True)
    if p.returncode == 0 and p.stdout.strip():
        return p.stdout.strip()
    return os.path.dirname(os.path.dirname(shutil.which("qemu-system-aarch64")))


def live_login(c, user="ubuntu", password=None):
    """Get from a cold serial console to a usable shell."""
    i = c.expect([r"\blogin:", r"PS [^\r\n]*>", r"bash-\d"], 900, "console")
    c.answering = True
    if i == 0:
        c.settle(quiet=1.5, timeout=30)
        c.send(user)
        j = c.expect([r"Password:", r"PS [^\r\n]*>", r"\$ $", r"# $"], 90,
                     "password or shell")
        if j == 0:
            c.send(password or "")
            c.expect([r"PS [^\r\n]*>", r"\$ $", r"# $"], 120, "shell")


def to_plain_bash(c):
    """The live console lands in pwsh (hook 0050). Drop to a bash whose prompt
    is unambiguous — `bash --norc` gives the distinctive `bash-5.x$`, which no
    amount of PSReadLine repainting can be mistaken for."""
    c.settle(quiet=2.0, timeout=60)
    for _ in range(3):
        c.drop()
        c.send("bash --norc")
        try:
            c.expect(r"bash-\d[\d.]*[#$]", 45, "plain bash prompt")
            return
        except SystemExit:
            print("    no bash prompt yet — retrying")
    raise SystemExit("could not reach a plain bash prompt")


