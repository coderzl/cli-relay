import { EventEmitter } from 'node:events'
import { existsSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { spawn, ChildProcess } from 'node:child_process'
import stripAnsi from 'strip-ansi'
import type { SessionConfig, SessionInfo, ApprovalMatch } from './types.js'

const MAX_SESSIONS = 10

// ── Agent 启动命令 ───────────────────────────────────────

const SAFE_CMD_RE = /^[a-zA-Z0-9\-_./~ ]+$/

function buildShellCmd(c: SessionConfig): string {
  let bin: string
  if (c.customCmd) {
    if (!SAFE_CMD_RE.test(c.customCmd)) {
      throw new Error(`Invalid custom command: ${c.customCmd}`)
    }
    bin = c.customCmd
  } else {
    bin = c.agent === 'custom' ? 'claude' : c.agent
  }

  const yoloFlags: Record<string, string> = {
    claude: '--dangerously-skip-permissions',
    codex: '--full-auto',
    qoder: '--yolo',
    custom: '--dangerously-skip-permissions',
  }
  const yoloFlag = c.yolo ? ` ${yoloFlags[c.agent] ?? ''}` : ''
  const prompt = c.prompt.trim() ? ` ${shellEscape(c.prompt)}` : ''
  return `${bin}${yoloFlag}${prompt}`
}

function shellEscape(s: string): string {
  return "'" + s.replace(/'/g, "'\\''") + "'"
}

// ── 审批检测 ─────────────────────────────────────────────

const APPROVAL_RE = [
  /Allow\s+.*\?/i,
  /Do you want to (run|execute|allow|proceed)/i,
  /\(y\/n\)/i,
  /approve this|permission required/i,
]

function detectApproval(text: string): ApprovalMatch | null {
  for (const re of APPROVAL_RE) {
    if (re.test(text)) {
      const lines = text.split('\n').filter((l) => l.trim())
      return {
        tool: lines.find((l) => re.test(l))?.trim() ?? 'tool',
        description: lines.slice(-8).join('\n'),
        rawContext: text.slice(-500),
      }
    }
  }
  return null
}

// ── Session 接口 ─────────────────────────────────────────

export interface Session {
  id: string
  config: SessionConfig
  status: 'running' | 'waiting_approval'
  startedAt: number
  write(data: string): void
  writeBinary(data: Buffer): void
  resize(cols: number, rows: number): void
  approve(): void
  deny(): void
  kill(): void
  info(): SessionInfo
}

// ── SessionManager ───────────────────────────────────────

export class SessionManager extends EventEmitter {
  private sessions = new Map<string, Session & { proc: ChildProcess }>()

  start(config: SessionConfig): Session {
    if (this.sessions.size >= MAX_SESSIONS) {
      throw new Error(`Max ${MAX_SESSIONS} concurrent sessions`)
    }

    if (!config.workDir || !existsSync(config.workDir)) {
      throw new Error(`Working directory does not exist: ${config.workDir}`)
    }

    const id = randomUUID().slice(0, 8)
    const shellCmd = buildShellCmd(config)
    const startedAt = Date.now()

    console.log(`[session] Starting: ${shellCmd.slice(0, 80)}...`)

    // Python PTY bridge: 真 PTY + 双向 stdin/stdout pipe
    const bridgePath = new URL('../pty-bridge.py', import.meta.url).pathname
    const proc = spawn('python3', [bridgePath, '120', '40', 'zsh', '-ilc', shellCmd], {
      cwd: config.workDir,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: {
        ...process.env,
        TERM: 'xterm-256color',
        COLUMNS: '120',
        LINES: '40',
      },
    })

    if (!proc.pid) {
      throw new Error(`Failed to spawn zsh`)
    }

    console.log(`[session] ${id} spawned (PID: ${proc.pid})`)

    // ── Raw 流: 低延迟 50ms flush → App ────────────────
    let rawBuf = Buffer.alloc(0)
    let rawTimer: ReturnType<typeof setTimeout> | null = null

    const flushRaw = () => {
      rawTimer = null
      if (rawBuf.length > 0) {
        this.emit('raw', id, rawBuf)
        rawBuf = Buffer.alloc(0)
      }
    }

    // ── Processed 流: 1s 聚合 → Discord ────────────────
    let textBuf = ''
    let textTimer: ReturnType<typeof setTimeout> | null = null

    const flushText = () => {
      textTimer = null
      if (!textBuf) return
      let clean = stripAnsi(textBuf)
      clean = clean
        .split('\n')
        .map((l) => { const p = l.split('\r'); return p[p.length - 1] })
        .join('\n')
        .replace(/\n{3,}/g, '\n\n')
        .trim()

      textBuf = ''
      if (!clean) return

      if (!config.yolo) {
        const m = detectApproval(clean)
        if (m) {
          session.status = 'waiting_approval'
          this.emit('approval', id, m)
        }
      }

      this.emit('processed', id, clean, clean.length > 3800)
    }

    const clearTimers = () => {
      if (rawTimer) { clearTimeout(rawTimer); rawTimer = null }
      if (textTimer) { clearTimeout(textTimer); textTimer = null }
    }

    const onData = (data: Buffer) => {
      // Raw path
      rawBuf = Buffer.concat([rawBuf, data])
      if (rawBuf.length > 4096) {
        if (rawTimer) clearTimeout(rawTimer)
        flushRaw()
      } else if (!rawTimer) {
        rawTimer = setTimeout(flushRaw, 50)
      }

      // Processed path
      textBuf += data.toString('utf-8')
      if (textBuf.length > 8000) {
        if (textTimer) clearTimeout(textTimer)
        flushText()
      } else if (!textTimer) {
        textTimer = setTimeout(flushText, 1000)
      }
    }

    proc.stdout?.on('data', onData)
    proc.stderr?.on('data', onData)

    proc.on('exit', (code) => {
      console.log(`[session] ${id} exited (code: ${code})`)
      clearTimers()
      flushRaw()
      flushText()
      this.emit('ended', id, code ?? 1)
      this.sessions.delete(id)
    })

    proc.on('error', (err) => {
      console.error(`[session] ${id} error:`, err.message)
      this.emit('ended', id, 1)
      this.sessions.delete(id)
    })

    const session: Session & { proc: ChildProcess } = {
      id,
      config,
      status: 'running',
      startedAt,
      proc,
      write: (d) => proc.stdin?.write(d),
      writeBinary: (d) => proc.stdin?.write(d),
      resize: () => {}, // child_process 不支持 resize，忽略
      approve() {
        proc.stdin?.write('y\n')
        this.status = 'running'
      },
      deny() {
        proc.stdin?.write('n\n')
        this.status = 'running'
      },
      kill() {
        clearTimers()
        proc.kill('SIGTERM')
      },
      info: () => ({
        id,
        agent: config.agent,
        workDir: config.workDir,
        yolo: config.yolo,
        status: session.status,
        startedAt,
      }),
    }

    this.sessions.set(id, session)
    this.emit('started', id, session.info())
    return session
  }

  get(id: string) { return this.sessions.get(id) }
  list(): SessionInfo[] { return [...this.sessions.values()].map((s) => s.info()) }

  killAll() {
    for (const s of this.sessions.values()) s.kill()
  }
}
