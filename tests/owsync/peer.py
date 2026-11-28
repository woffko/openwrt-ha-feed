#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# A peer that speaks owsync's wire protocol (plain mode) by hand, for what
# two real daemons cannot be made to do at a chosen moment: cut a session
# after the first file, send content that is not what was announced, send a
# file nobody asked for, or wait in the middle of a session while the test
# edits a file. It connects to a daemon from the address the daemon knows
# as its peer.
#
#   peer.py SCENARIO DAEMON_HOST PORT SOURCE_ADDR [name=value ...]
#
# Files are given as file=NAME:CONTENT (repeatable). Other settings:
#   age=SECONDS      the announced date lies this far in the past (default 0;
#                    negative for the future)
#   ready=PATH go=PATH   scenario "hold": PATH "ready" is created once the
#                    daemon has asked for its files, and the content is sent
#                    when PATH "go" exists
# Scenarios:
#   give             announces the files and sends what the daemon asks for
#   cut-after-first  sends the first file asked for and drops the connection
#   wrong-content    announces the files and sends other content for them
#   unasked          announces nothing and sends the files all the same
#   hold             as "give", waiting for "go" before the content is sent
#   take-and-drop    announces nothing, asks for the file want=NAME and says
#                    it is done, all at once; reads 64 KiB of what the
#                    daemon sends and drops the connection
# Prints what the daemon asked for. Exit code 0 when the scenario ran.
import hashlib
import json
import os
import socket
import struct
import sys
import time


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def recv_message(sock):
    header = recv_exact(sock, 4)
    if header is None:
        return None
    (length,) = struct.unpack(">I", header)
    payload = recv_exact(sock, length)
    if payload is None:
        return None
    return json.loads(payload.decode())


def send(sock, message):
    payload = json.dumps(message).encode()
    sock.sendall(struct.pack(">I", len(payload)) + payload)


def main():
    scenario, host, port, source = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    files, settings = [], {}
    for arg in sys.argv[5:]:
        name, _, value = arg.partition("=")
        if name == "file":
            path, _, content = value.partition(":")
            files.append((path, content.encode()))
        else:
            settings[name] = value
    mtime = int((time.time() - float(settings.get("age", "0"))) * 1000)

    # The daemon turns a connection away while another session of its own
    # runs (it closes before its Hello): tried again, as a real peer does
    sock = None
    for _ in range(20):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.bind((source, 0))
        sock.settimeout(20)
        sock.connect((host, port))
        if recv_message(sock) is not None:
            break
        sock.close()
        sock = None
        time.sleep(0.3)
    if sock is None:
        print("no Hello from the daemon")
        return 1
    send(sock, {"type": "Hello", "hostname": "scripted-peer", "timestamp": int(time.time()), "version": 1})

    theirs = recv_message(sock)
    if theirs is None or theirs.get("type") != "SyncState":
        print("no SyncState from the daemon")
        return 1

    if scenario == "take-and-drop":
        for message in ({"type": "SyncState", "files": []},
                        {"type": "RequestFiles", "paths": [settings["want"]]},
                        {"type": "EndOfSync"}):
            send(sock, message)
        recv_exact(sock, 65536)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        sock.close()
        print("dropped while the daemon was sending")
        return 0

    announced = []
    if scenario != "unasked":
        for path, content in files:
            announced.append({"path": path, "hash": hashlib.sha256(content).hexdigest(), "mtime": mtime,
                              "size": len(content), "mode": 0o644, "deleted": False})
    send(sock, {"type": "SyncState", "files": announced})
    send(sock, {"type": "RequestFiles", "paths": []})

    asked, ended = None, False
    while asked is None:
        message = recv_message(sock)
        if message is None:
            print("the daemon closed before it asked for anything")
            return 1
        if message.get("type") == "RequestFiles":
            asked = message.get("paths", [])
        elif message.get("type") == "EndOfSync":
            ended = True
    print("asked for: %s" % " ".join(asked))

    if scenario == "hold":
        open(settings["ready"], "w").close()
        while not os.path.exists(settings["go"]):
            time.sleep(0.05)

    contents = dict(files)
    to_send = [p for p, _ in files] if scenario == "unasked" else [p for p in asked if p in contents]
    for index, path in enumerate(to_send):
        data = contents[path]
        if scenario == "wrong-content":
            data = b"not what was announced\n"
        send(sock, {"type": "FileContent", "path": path, "mode": 0o644, "data": data.hex()})
        if scenario == "cut-after-first" and index == 0:
            time.sleep(0.5)  # the daemon writes the file
            # Dropped, not closed: a reset, as when the link goes
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            sock.close()
            print("cut after: %s" % path)
            return 0

    send(sock, {"type": "EndOfSync"})
    while not ended:
        message = recv_message(sock)
        if message is None:
            break
        if message.get("type") == "EndOfSync":
            ended = True
    time.sleep(0.3)  # the daemon ends its side before the socket goes
    sock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
