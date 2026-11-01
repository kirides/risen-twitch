#!/usr/bin/env python3
"""A stand-in for the Twitch bridge: hosts \\\\.\\pipe\\__TwitchIntegration_Kirides_Conn, sends the lines given as arguments the moment the game connects
(and after --every seconds again), prints what the game writes back. Windows only (ctypes, no pywin32).

    python tools/fake_bridge.py '{"type":"streamelements-perk","data":{"title":"Gold","redeemer":"early"}}' [--name PIPE] [--seconds 600] [--every 0]

Speaks the protocol of twitch-integration-connector.exe: a MESSAGE pipe, every message a 2-byte little-endian length plus JSON, a {"type":"ping"} every 5 s.
"""
import argparse
import ctypes
import sys
import time
from ctypes import wintypes

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.CreateNamedPipeW.restype = wintypes.HANDLE
k32.CreateNamedPipeW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID]
k32.ConnectNamedPipe.argtypes = [wintypes.HANDLE, wintypes.LPVOID]
k32.ReadFile.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
k32.WriteFile.argtypes = [wintypes.HANDLE, wintypes.LPCVOID, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
k32.PeekNamedPipe.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), ctypes.POINTER(wintypes.DWORD), ctypes.POINTER(wintypes.DWORD)]
INVALID = wintypes.HANDLE(-1).value
PIPE_ACCESS_DUPLEX, PIPE_MESSAGE_MODE = 3, 6  # PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE, blocking


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lines", nargs="*")
    ap.add_argument("--name", default="__TwitchIntegration_Kirides_Conn")
    ap.add_argument("--seconds", type=float, default=600)
    ap.add_argument("--every", type=float, default=0, help="send the lines again every N seconds while connected")
    ap.add_argument("--file", help="read the messages from this file, one per line (avoids shell quoting of the JSON)")
    a = ap.parse_args()
    if a.file:
        with open(a.file, encoding="utf-8") as f:
            a.lines += [ln.strip() for ln in f if ln.strip()]
    path = "\\\\.\\pipe\\" + a.name
    h = k32.CreateNamedPipeW(path, PIPE_ACCESS_DUPLEX, PIPE_MESSAGE_MODE, 1, 65536, 65536, 0, None)
    if h in (None, INVALID):
        print("cannot create", path, ctypes.get_last_error()); return 1
    print("waiting for the game on", path, flush=True)
    deadline = time.time() + a.seconds
    # ConnectNamedPipe blocks; the watchdog is the caller (test-run kills this process after the run)
    if not k32.ConnectNamedPipe(h, None) and ctypes.get_last_error() != 535:  # ERROR_PIPE_CONNECTED
        print("connect failed", ctypes.get_last_error()); return 1
    print("game connected", flush=True)

    def send(text):
        payload = text.encode("utf-8")
        data = len(payload).to_bytes(2, "little") + payload
        n = wintypes.DWORD()
        ok = k32.WriteFile(h, data, len(data), ctypes.byref(n), None)
        print("->", text, "ok" if ok else "FAILED", flush=True)
        return bool(ok)

    for line in a.lines:
        send(line)
    last = time.time()
    last_ping = time.time()
    buf = ctypes.create_string_buffer(4096)
    while time.time() < deadline:
        avail = wintypes.DWORD()
        if not k32.PeekNamedPipe(h, None, 0, None, ctypes.byref(avail), None):
            print("game disconnected", flush=True); break
        if avail.value:
            n = wintypes.DWORD()
            k32.ReadFile(h, buf, 4096, ctypes.byref(n), None)
            for ln in buf.raw[: n.value].decode("utf-8", "replace").splitlines():
                print("<-", ln, flush=True)
        if time.time() - last_ping >= 5:
            last_ping = time.time()
            send('{"type":"ping"}')
        if a.every and time.time() - last >= a.every:
            last = time.time()
            for line in a.lines:
                send(line)
        time.sleep(0.1)
    k32.CloseHandle(h)
    return 0


if __name__ == "__main__":
    sys.exit(main())
