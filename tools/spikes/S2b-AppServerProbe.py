"""Spike S2b helper: JSON-RPC (JSONL over stdio) client for `codex app-server` with a TEST CODEX_HOME.

Spike tooling only (not product code). Refuses any home outside
%USERPROFILE%\\.codex-profiles\\spike* or %TEMP%\\harness-spike\\ and refuses the real ~\\.codex.

Usage: python S2b-AppServerProbe.py <codex_home> <calls.json> [timeout_sec] [max_chars]
calls.json = JSON array of {"method": ..., "params": {...}}. Prints one line per response.
(The PowerShell attempt, a .NET Process with redirected stdin, made codex reject line 1 as
"expected value at line 1 column 1"; the same bytes written from Python are accepted.)
"""
import json
import os
import subprocess
import sys
import threading
import queue

home = os.path.abspath(sys.argv[1])
calls = json.load(open(sys.argv[2], encoding="utf-8-sig"))
timeout = int(sys.argv[3]) if len(sys.argv) > 3 else 60
max_chars = int(sys.argv[4]) if len(sys.argv) > 4 else 1500

roots = [
    os.path.join(os.environ["USERPROFILE"], ".codex-profiles", "spike").lower(),
    os.path.join(os.environ["TEMP"], "harness-spike").lower() + os.sep,
]
if not any(home.lower().startswith(r) for r in roots):
    sys.exit("Refusing CODEX_HOME outside test roots: " + home)
if home.lower() == os.path.join(os.environ["USERPROFILE"], ".codex").lower():
    sys.exit("Refusing real ~\\.codex")

exe = os.path.expandvars(
    r"%APPDATA%\npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64"
    r"\vendor\x86_64-pc-windows-msvc\bin\codex.exe")
env = dict(os.environ, CODEX_HOME=home)
p = subprocess.Popen([exe, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, env=env)
q = queue.Queue()
threading.Thread(target=lambda: [q.put(l) for l in iter(p.stdout.readline, b"")], daemon=True).start()


def send(o):
    p.stdin.write((json.dumps(o) + "\n").encode())
    p.stdin.flush()


def recv(i):
    while True:
        try:
            line = q.get(timeout=timeout)
        except queue.Empty:
            return None
        m = json.loads(line)
        if m.get("id") == i and ("result" in m or "error" in m):
            return line.decode()


try:
    send({"id": 0, "method": "initialize", "params": {
        "clientInfo": {"name": "harness-spike", "version": "0"}, "capabilities": {}}})
    print("initialize ->", (recv(0) or "NO RESPONSE")[:200])
    send({"method": "initialized"})
    for n, c in enumerate(calls, 1):
        send({"id": n, "method": c["method"], "params": c.get("params", {})})
        print(c["method"], "->", (recv(n) or "NO RESPONSE")[:max_chars])
finally:
    p.kill()
