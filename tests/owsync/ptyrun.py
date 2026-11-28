#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# Runs a command on a terminal of its own and copies what it prints to
# standard output. An owsync daemon logs to the system log only, and to its
# standard error as well when that is a terminal: this is how the tests get
# to read its log. The command's process id is written to the file given.
#   ptyrun.py PIDFILE COMMAND [ARG...]
import os
import pty
import sys

pidfile, argv = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
with open(pidfile, "w") as f:
    f.write(str(pid))
out = sys.stdout.buffer
while True:
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    out.write(data.replace(b"\r\n", b"\n"))
    out.flush()
os.waitpid(pid, 0)
