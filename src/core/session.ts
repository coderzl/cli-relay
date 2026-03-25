import { EventEmitter } from 'node:events'
import { existsSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import pty from 'node-pty'
import stripAnsi from 'strip-ansi'
import type { SessionConfig, SessionInfo, ApprovalMatch } from './types.js'

const MAX_SESSIONS = 10

// ── Agent 启动命令 ───────────────────────────────────────

// customCmd 白名单: 仅允许字母、数字、-_./ 和空格
const SAFE_CMD_RE = /^[a-zA-Z0-9\-_./~ ]+$/

function agentCmd(c: SessionConfig): [string, string[]] {
  if (c.customCmd) {
    if (!SAFE_CMD_RE.test(c.customCmd)) {
      throw new Error(`Invalid custom command: ${c.customCmd}`)
    }
    const yoloFlag = c.yolo ? ' --dangerously-skip-permissions' : ''
    const fullCmd = `${c.customCmd}${yoloFlag} ${shellEscape(c.prompt)}`
    return ['zsh', ['-ilc', fullCmd]]
  }

  switch (c.agent) {
    case 'claude':
      return ['claude', c.yolo ? ['--dangerously-skip-permissions', c.prompt] : [c.prompt]]
    case 'codex':
      return ['codex', c.yolo ? ['--full-auto', c.prompt] : [c.prompt]]
    case 'qoder':
      return ['qoder', c.yolo ? ['--yolo', c.prompt] : [c.prompt]]
    case 'custom':
      return ['claude', [c.prompt]]
  }
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

// ── 清理 env ─────────────────────────────────────────────

function cleanEnv(): Record<string, string> {
  const env: Record<string, string> = {}
  for (const [k, v] of Object.entries(process.env)) {
    if (v !== undefined) env[k] = v
  }
  return env
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
//
// 双路事件:
//   'raw'       (sid, Buffer)         → App WS: 原始 PTY 字节
//   'processed' (sid, string, isLong) → Discord: 清理后文本
//   'approval'  (sid, ApprovalMatch)  → 两端: 权限请求
//   'started'   (sid, SessionInfo)    → 两端: 会话启动
//   'ended'     (sid, exitCode)       → 两端: 会话结束

export class SessionManager extends EventEmitter {
  private sessions = new Map<string, Session & { pty: pty.IPty }>()

  start(config: SessionConfig): Session {
    // 并发会话限制
    if (this.sessions.size >= MAX_SESSIONS) {
      throw new Error(`Max ${MAX_SESSIONS} concurrent sessions`)
    }

    // 验证 workDir
    if (!config.workDir || !existsSync(config.workDir)) {
      throw new Error(`Working directory does not exist: ${config.workDir}`)
    }

    // 唯一 ID (无碰撞)
    const id = randomUUID().slice(0, 8)
    const [cmd, args] = agentCmd(config)
    const startedAt = Date.now()

    // PTY 启动 (catch spawn failure)
    let term: pty.IPty
    try {
      term = pty.spawn(cmd, args, {
        name: 'xterm-256color',
        cols: 120,
        rows: 40,
        cwd: config.workDir,
        env: cleanEnv(),
      })
    } catch (e) {
      throw new Error(`Failed to spawn ${cmd}: ${(e as Error).message}`)
    }

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

    term.onData((data) => {
      const buf = Buffer.from(data, 'utf-8')
      rawBuf = Buffer.concat([rawBuf, buf])
      if (rawBuf.length > 4096) {
        if (rawTimer) clearTimeout(rawTimer)
        flushRaw()
      } else if (!rawTimer) {
        rawTimer = setTimeout(flushRaw, 50)
      }

      textBuf += data
      if (textBuf.length > 8000) {
        if (textTimer) clearTimeout(textTimer)
        flushText()
      } else if (!textTimer) {
        textTimer = setTimeout(flushText, 1000)
      }
    })

    term.onExit(({ exitCode }) => {
      clearTimers()
      flushRaw()
      flushText()
      this.emit('ended', id, exitCode)
      this.sessions.delete(id)
    })

    const session: Session & { pty: pty.IPty } = {
      id,
      config,
      status: 'running',
      startedAt,
      pty: term,
      write: (d) => term.write(d),
      writeBinary: (d) => term.write(d.toString('utf-8')),
      resize: (cols, rows) => {
        if (cols > 0 && rows > 0) term.resize(cols, rows)
      },
      approve() {
        term.write('y\n')
        this.status = 'running'
      },
      deny() {
        term.write('n\n')
        this.status = 'running'
      },
      kill() {
        clearTimers()
        term.kill()
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
    // 只 kill，让 onExit 自然清理
    for (const s of this.sessions.values()) s.kill()
  }
}
