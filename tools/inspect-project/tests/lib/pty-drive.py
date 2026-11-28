#!/usr/bin/env python3
"""Run a command with a pseudo-terminal on stdin and stderr, and feed it a script.

WHY THIS EXISTS. inspect-project.sh drops into its interactive menu only when BOTH
stdin and stderr are terminals — deliberately, so an agent with a missing flag
fails fast instead of blocking on a read nobody will answer. A plain pipe
therefore cannot reach the menu at all, and the menu is a third of the tool's
surface. This driver supplies the terminal.

THE FD LAYOUT IS THE POINT, not an implementation detail:

    stdin  <- pty slave    the menu's `read -r` sees a terminal
    stderr -> pty slave    `[ -t 2 ]` passes, and every prompt is written here
    stdout -> a PIPE       NOT a terminal

That last line is what makes this a faithful test rather than a convenient one.
inspect-project's whole channel contract is "stdout is the machine channel, and
the interactive path must not corrupt it", and a driver that put stdout on the pty
too would merge the prompts into the payload and make that contract unassertable.

WHAT THIS PROCESS EMITS, so the shell harness needs no extra files:

    its own stdout   the child's stdout, byte for byte  -> $CUR_OUT
    its own stderr   the terminal transcript: prompts, diagnostics, and the
                     tty's own echo of the scripted input -> $CUR_ERR
    its exit status  the child's exit status             -> $CUR_RC

Carriage returns are stripped from the transcript before it is written, because a
terminal ends lines with CRLF and every assertion against it is a plain substring
match.

INPUT IS WRITTEN VERBATIM, bytes and all, so a test can send a raw EOT (0x04) to
exercise "a closed stdin reads as a quit" without closing the pty and racing a
SIGHUP against the child's own teardown.

THERE IS A DEADLINE, and it is not defensive padding. A terminal read blocks
forever, so a menu that asks one more question than the scripted input answers
would hang the whole suite rather than fail it — which is exactly what a mutation
that makes a prompt fire when it should not looks like. On expiry the child is
killed and this process exits 124 (the conventional timeout status), so the
scenario shows up as a red test with a named reason.

Usage:  pty-drive.py [--timeout SECONDS] --input FILE -- COMMAND [ARG...]
"""

import errno
import fcntl
import os
import pty
import select
import signal
import sys
import termios
import time

READ_CHUNK = 65536
DEFAULT_TIMEOUT_SECONDS = 60.0
TIMEOUT_EXIT_STATUS = 124


def parse_args(argv):
    timeout = DEFAULT_TIMEOUT_SECONDS
    if len(argv) >= 2 and argv[0] == "--timeout":
        timeout = float(argv[1])
        argv = argv[2:]
    if len(argv) < 4 or argv[0] != "--input" or argv[2] != "--":
        sys.stderr.write(
            "usage: pty-drive.py [--timeout SECONDS] --input FILE -- COMMAND [ARG...]\n"
        )
        raise SystemExit(2)
    return timeout, argv[1], argv[3:]


def spawn(command, pty_slave, stdout_write):
    """Fork COMMAND with the fd layout described in this module's docstring."""
    pid = os.fork()
    if pid != 0:
        return pid

    os.setsid()
    try:
        fcntl.ioctl(pty_slave, termios.TIOCSCTTY, 0)
    except OSError:
        # A controlling terminal is not required for isatty() to be true; the
        # session leader call above is best-effort realism, not a precondition.
        pass
    os.dup2(pty_slave, 0)
    os.dup2(stdout_write, 1)
    os.dup2(pty_slave, 2)
    for fd in (pty_slave, stdout_write):
        if fd > 2:
            os.close(fd)
    try:
        os.execvp(command[0], command)
    finally:
        os._exit(127)


def drain(sources, deadline):
    """Read every source to EOF or until DEADLINE, returning ({fd: bytes}, timed_out).

    A pty master reports the far end's exit as EIO rather than as EOF on some
    platforms and as an empty read on others; both mean the same thing here.
    """
    collected = {fd: b"" for fd in sources}
    open_fds = list(sources)
    while open_fds:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return collected, True
        ready, _, _ = select.select(open_fds, [], [], remaining)
        if not ready:
            return collected, True
        for fd in ready:
            try:
                chunk = os.read(fd, READ_CHUNK)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                chunk = b""
            if chunk:
                collected[fd] += chunk
            else:
                open_fds.remove(fd)
    return collected, False


def main():
    timeout, input_path, command = parse_args(sys.argv[1:])
    with open(input_path, "rb") as handle:
        scripted_input = handle.read()

    pty_master, pty_slave = pty.openpty()
    stdout_read, stdout_write = os.pipe()

    child = spawn(command, pty_slave, stdout_write)
    os.close(pty_slave)
    os.close(stdout_write)

    if scripted_input:
        os.write(pty_master, scripted_input)

    collected, timed_out = drain([pty_master, stdout_read], time.monotonic() + timeout)

    if timed_out:
        os.kill(child, signal.SIGKILL)
    _, status = os.waitpid(child, 0)

    sys.stdout.buffer.write(collected[stdout_read])
    sys.stdout.buffer.flush()
    sys.stderr.buffer.write(collected[pty_master].replace(b"\r", b""))
    if timed_out:
        sys.stderr.write(
            "\npty-drive.py: the command was still running after %gs and was killed"
            " — the scripted input probably answers fewer questions than it asks\n"
            % timeout
        )
    sys.stderr.flush()

    if timed_out:
        raise SystemExit(TIMEOUT_EXIT_STATUS)
    if os.WIFSIGNALED(status):
        raise SystemExit(128 + os.WTERMSIG(status))
    raise SystemExit(os.WEXITSTATUS(status))


if __name__ == "__main__":
    main()
