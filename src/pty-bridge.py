#!/usr/bin/env python3
"""
PTY Bridge: 在真 PTY 中运行命令，stdin/stdout 通过 pipe 转发。
用法: python3 pty-bridge.py <cols> <rows> <cmd> [args...]
"""
import sys, os, pty, select, signal, struct, fcntl, termios

if len(sys.argv) < 4:
    print("Usage: pty-bridge.py <cols> <rows> <cmd> [args...]", file=sys.stderr)
    sys.exit(1)

cols = int(sys.argv[1])
rows = int(sys.argv[2])
cmd = sys.argv[3:]

# Fork PTY
pid, fd = pty.fork()

if pid == 0:
    # Child: 设置终端尺寸，exec 命令
    winsize = struct.pack('HHHH', rows, cols, 0, 0)
    fcntl.ioctl(sys.stdout.fileno(), termios.TIOCSWINSZ, winsize)
    os.environ['TERM'] = 'xterm-256color'
    os.environ['COLUMNS'] = str(cols)
    os.environ['LINES'] = str(rows)
    os.execvp(cmd[0], cmd)
else:
    # Parent: 设置 PTY 尺寸
    winsize = struct.pack('HHHH', rows, cols, 0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)

    # 设置 stdin 为非阻塞
    flags = fcntl.fcntl(sys.stdin.fileno(), fcntl.F_GETFL)
    fcntl.fcntl(sys.stdin.fileno(), fcntl.F_SETFL, flags | os.O_NONBLOCK)

    # 转发 SIGWINCH
    def on_winch(sig, frame):
        pass
    signal.signal(signal.SIGWINCH, on_winch)

    stdin_open = True  # #9 修复: 追踪 stdin 是否仍然打开

    # 主循环: 双向转发 stdin ↔ PTY
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
                            # stdin EOF — 停止监听 stdin，但不终止（让子进程继续）
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

            # 检查子进程是否退出
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
                sys.exit(os.WEXITSTATUS(result[1]) if os.WIFEXITED(result[1]) else 1)
    except KeyboardInterrupt:
        os.kill(pid, signal.SIGTERM)
        sys.exit(0)
    except OSError:
        sys.exit(0)
