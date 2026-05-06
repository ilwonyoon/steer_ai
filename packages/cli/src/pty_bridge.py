#!/usr/bin/env python3
import os
import pty
import select
import signal
import struct
import sys
import termios
import tty
import fcntl


def set_pty_size(fd):
    rows = int(os.environ.get("STEER_PTY_ROWS", "24"))
    cols = int(os.environ.get("STEER_PTY_COLS", "80"))
    size = struct.pack("HHHH", rows, cols, 0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, size)


def main():
    if len(sys.argv) < 2:
        print("usage: pty_bridge.py <command> [...args]", file=sys.stderr)
        return 2

    command = sys.argv[1]
    args = sys.argv[1:]
    pid, master_fd = pty.fork()

    if pid == 0:
        os.execvpe(command, args, os.environ)

    set_pty_size(master_fd)
    old_attrs = None
    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()

    if sys.stdin.isatty():
        old_attrs = termios.tcgetattr(stdin_fd)
        tty.setraw(stdin_fd)

    def restore_terminal():
        if old_attrs is not None:
            termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old_attrs)

    def handle_winch(signum, frame):
        set_pty_size(master_fd)
        os.kill(pid, signal.SIGWINCH)

    signal.signal(signal.SIGWINCH, handle_winch)

    try:
        while True:
            readable, _, _ = select.select([stdin_fd, master_fd], [], [])

            if master_fd in readable:
                try:
                    data = os.read(master_fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                os.write(stdout_fd, data)

            if stdin_fd in readable:
                data = os.read(stdin_fd, 4096)
                if data:
                    os.write(master_fd, data)
    finally:
        restore_terminal()

    _, status = os.waitpid(pid, 0)
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
