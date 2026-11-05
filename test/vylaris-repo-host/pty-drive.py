#!/usr/bin/env python3
"""pty-drive.py - run a command on a pseudo terminal and answer its prompts (helper of guest.sh).

usage: pty-drive.py [--timeout SECONDS] [--idle SECONDS] [--stdin-null] [--env NAME=VALUE]... [--unset NAME]... [--token-env NAME]
                    [--step 'REGEX=>ANSWER']... -- COMMAND [ARGUMENT]...

The command gets a terminal as standard input, output and error. Each --step waits (in order) until its
REGEX (Python, matched against what the command printed since the previous step) appears, waits a
moment, and types ANSWER and Enter. In an ANSWER, the text @TOKEN@ is replaced by the value of the
environment variable PTY_TOKEN of this program (so a secret never appears on a command line), and the
whole answer @EOF@ sends Ctrl+D instead of a line. The environment of the command is this program's
environment without PTY_TOKEN, changed by --unset and --env; --token-env NAME puts the value of
PTY_TOKEN into the variable NAME of the command (a secret in an environment variable, not on a command
line).

--stdin-null gives the command /dev/null as standard input (output and error stay on the terminal).

--timeout is the longest the whole run may take (default 600), --idle the longest the command may print
nothing (default 120): a command that waits for an answer nobody gives is stopped, not waited for.

Everything the terminal shows (including the echo of typed answers; a hidden prompt echoes nothing) goes
to standard output, with the line ends changed to plain newlines. The last lines say how it ended:
  PTY_STEPS_LEFT=N   steps that never matched (0: all answered)
  PTY_EXIT=N         exit status of the command (128+signal if it was killed; 124: timeout or idle)
"""

import os
import pty
import re
import select
import signal
import sys
import time


def main(argv):
    timeout = 600.0
    idle = 120.0
    stdin_null = False
    env = dict(os.environ)
    token = env.pop("PTY_TOKEN", "")
    steps = []
    i = 0
    while i < len(argv) and argv[i] != "--":
        opt = argv[i]
        if opt == "--timeout":
            timeout = float(argv[i + 1])
        elif opt == "--stdin-null":
            stdin_null = True
            i += 1
            continue
        elif opt == "--idle":
            idle = float(argv[i + 1])
        elif opt == "--env":
            name, _, value = argv[i + 1].partition("=")
            env[name] = value
        elif opt == "--unset":
            env.pop(argv[i + 1], None)
        elif opt == "--token-env":
            env[argv[i + 1]] = token
        elif opt == "--step":
            pattern, sep, answer = argv[i + 1].partition("=>")
            if not sep:
                print("pty-drive: a step needs REGEX=>ANSWER", file=sys.stderr)
                return 2
            steps.append((re.compile(pattern.encode()), answer))
        else:
            print("pty-drive: unknown option " + opt, file=sys.stderr)
            return 2
        i += 2
    command = argv[i + 1:]
    if not command:
        print("pty-drive: no command after --", file=sys.stderr)
        return 2

    pid, fd = pty.fork()
    if pid == 0:
        if stdin_null:
            os.dup2(os.open("/dev/null", os.O_RDONLY), 0)
        try:
            os.execvpe(command[0], command, env)
        except OSError as exc:
            print("pty-drive: cannot run %s: %s" % (command[0], exc))
            os._exit(127)

    transcript = b""
    pending = b""  # output since the last step matched
    current = 0
    status = None
    deadline = time.time() + timeout
    last_output = time.time()
    timed_out = False
    while True:
        if time.time() > deadline or time.time() - last_output > idle:
            timed_out = True
            os.kill(pid, signal.SIGKILL)
            break
        ready, _, _ = select.select([fd], [], [], 0.5)
        if ready:
            try:
                data = os.read(fd, 65536)
            except OSError:
                data = b""
            if not data:
                break
            last_output = time.time()
            transcript += data
            pending += data
            while current < len(steps):
                found = steps[current][0].search(pending)
                if not found:
                    break
                pending = pending[found.end():]
                answer = steps[current][1]
                time.sleep(0.3)
                if answer == "@EOF@":
                    os.write(fd, b"\x04")
                else:
                    os.write(fd, answer.replace("@TOKEN@", token).encode() + b"\n")
                current += 1
    try:
        _, raw = os.waitpid(pid, 0)
        if os.WIFEXITED(raw):
            status = os.WEXITSTATUS(raw)
        else:
            status = 128 + os.WTERMSIG(raw)
    except ChildProcessError:
        status = 1
    if timed_out:
        status = 124
    text = transcript.decode(errors="replace").replace("\r\n", "\n").replace("\r", "\n")
    sys.stdout.write(text)
    if not text.endswith("\n"):
        sys.stdout.write("\n")
    print("PTY_STEPS_LEFT=%d" % (len(steps) - current))
    print("PTY_EXIT=%d" % status)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
