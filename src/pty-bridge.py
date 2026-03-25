#!/usr/bin/env python3
"""
PTY Bridge: 在真 PTY 中运行命令，stdin/stdout 通过 pipe 转发。
用法: python3 pty-bridge.py <cols> <rows> <cmd> [args...]
"""
import sys, os, pty, select, signal, struct, fcntl, termios, time

if len(sys.argv) < 4:
    print("Usage: pty-bridge.py <cols> <rows> <cmd> [args...]", file=sys.stderr)
    sys.exit(1)

cols = int(sys.argv[1])
rows = int(sys.argv[2])
cmd = sys.argv[3:]

pid, fd = pty.fork()

if pid == 0:
    # Child
    winsize = struct.pack('HHHH', rows, cols, 0, 0)
    fcntl.ioctl(sys.stdout.fileno(), termios.TIOCSWINSZ, winsize)
    os.environ['TERM'] = 'xterm-256color'
    os.environ['COLUMNS'] = str(cols)
    os.environ['LINES'] = str(rows)
    os.execvp(cmd[0], cmd)
else:
    # Parent
    winsize = struct.pack('HHHH', rows, cols, 0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)

    flags = fcntl.fcntl(sys.stdin.fileno(), fcntl.F_GETFL)
    fcntl.fcntl(sys.stdin.fileno(), fcntl.F_SETFL, flags | os.O_NONBLOCK)

    # [M7+B4] SIGTERM 转发，非阻塞等待
    def on_term(sig, frame):
        try:
            os.kill(pid, signal.SIGTERM)
            # 非阻塞等待子进程退出
            for _ in range(10):
                result = os.waitpid(pid, os.WNOHANG)
                if result[0] != 0:
                    break
                time.sleep(0.05)
            else:
                os.kill(pid, signal.SIGKILL)
        except (ProcessLookupError, ChildProcessError):
            pass
        try:
            os.close(fd)
        except OSError:
            pass
        sys.exit(0)
    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGWINCH, lambda s, f: None)

    stdin_open = True

    try:
        while True:
            fds_to_watch = [fd]
            if stdin_open:
                fds_to_watch.append(sys.stdin.fileno())

            rlist, _, _ = select.select(fds_to_watch, [], [], 0.1)

            for r in rlist:
                if r == sys.stdin.fileno():
                    try:
                        data = os.read(sys.stdin.fileno(), 4096)
                        if not data:
                            stdin_open = False
                            continue
                        os.write(fd, data)
                    except (OSError, IOError):
                        stdin_open = False
                elif r == fd:
                    try:
                        data = os.read(fd, 4096)
                        if not data:
                            break
                        os.write(sys.stdout.fileno(), data)
                        sys.stdout.flush()
                    except (OSError, IOError):
                        break

            result = os.waitpid(pid, os.WNOHANG)
            if result[0] != 0:
                # 读完剩余输出
                try:
                    while True:
                        data = os.read(fd, 4096)
                        if not data:
                            break
                        os.write(sys.stdout.fileno(), data)
                except (OSError, IOError):
                    pass
                try: os.close(fd)
                except OSError: pass
                sys.exit(os.WEXITSTATUS(result[1]) if os.WIFEXITED(result[1]) else 1)
    except KeyboardInterrupt:
        os.kill(pid, signal.SIGTERM)
        try: os.close(fd)
        except OSError: pass
        sys.exit(0)
    except OSError:
        try: os.close(fd)
        except OSError: pass
        sys.exit(0)
