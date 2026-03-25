import { EventEmitter } from 'node:events'
import { existsSync, realpathSync } from 'node:fs'
import { randomUUID, timingSafeEqual, createHmac } from 'node:crypto'
import { resolve } from 'node:path'
import { spawn, ChildProcess } from 'node:child_process'
import stripAnsi from 'strip-ansi'
import type { SessionConfig, SessionInfo, ApprovalMatch } from './types.js'

const MAX_SESSIONS = 10
const CR = '\r'

// [C1+C3] Agent 白名单
const VALID_AGENTS = ['claude', 'codex', 'qoder', 'custom'] as const

// ── Agent 启动命令 ───────────────────────────────────────

const SAFE_CMD_RE = /^[a-zA-Z0-9\-_./~ ]+$/

function buildShellCmd(c: SessionConfig): string {
  // [C1] 严格校验 agent
  if (!(VALID_AGENTS as readonly string[]).includes(c.agent)) {
    throw new Error(`Invalid agent: ${c.agent}`)
  }

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
  const extraFlags: Record<string, string> = {
    claude: '--permission-mode bypassPermissions',
  }
  const yoloFlag = c.yolo ? ` ${yoloFlags[c.agent] ?? ''}` : ''
  const extra = extraFlags[c.agent] ?? ''
  const prompt = c.prompt.trim() ? ` ${shellEscape(c.prompt)}` : ''
  return `${bin}${yoloFlag}${extra ? ' ' + extra : ''}${prompt}`
}

function shellEscape(s: string): string {
  return "'" + s.replace(/'/g, "'\\''") + "'"
}

// ── 常量比较（防时序攻击）───────────────────────────────

export function safeTokenEqual(a: string, b: string): boolean {
  // HMAC 使长度一致，防止长度泄露
  const key = 'cli-relay-token-compare'
  const ha = createHmac('sha256', key).update(a).digest()
  const hb = createHmac('sha256', key).update(b).digest()
  return timingSafeEqual(ha, hb)
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

  constructor() {
    super()
    this.setMaxListeners(20) // [L5] app-server + discord 各注册多个 listener
  }

  start(config: SessionConfig): Session {
    if (this.sessions.size >= MAX_SESSIONS) {
      throw new Error(`Max ${MAX_SESSIONS} concurrent sessions`)
    }

    if (!config.workDir || !existsSync(config.workDir)) {
      throw new Error(`Working directory does not exist: ${config.workDir}`)
    }

    // [H5+B1] workDir 路径限制 — realpathSync 防 symlink 绕过
    const allowedBase = realpathSync(resolve(process.env.WORK_DIR ?? process.env.HOME ?? '/'))
    let resolvedDir: string
    try {
      resolvedDir = realpathSync(config.workDir)
    } catch {
      throw new Error(`workDir not accessible: ${config.workDir}`)
    }
    if (!resolvedDir.startsWith(allowedBase) && resolvedDir !== allowedBase) {
      throw new Error(`workDir must be under ${allowedBase}, got: ${resolvedDir}`)
    }

    // [H1] 防碰撞 ID
    let id: string
    do { id = randomUUID().slice(0, 12) } while (this.sessions.has(id))

    const shellCmd = buildShellCmd(config)
    const startedAt = Date.now()

    console.log(`[session] Starting: ${shellCmd.slice(0, 80)}...`)

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
      throw new Error('Failed to spawn process')
    }

    console.log(`[session] ${id} spawned (PID: ${proc.pid})`)

    // ── Raw 流: 低延迟 50ms flush → App
    let rawBuf = Buffer.alloc(0)
    let rawTimer: ReturnType<typeof setTimeout> | null = null

    const flushRaw = () => {
      rawTimer = null
      if (rawBuf.length > 0) {
        this.emit('raw', id, rawBuf)
        rawBuf = Buffer.alloc(0)
      }
    }

    // ── Processed 流: 1s 聚合 → Discord
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

    // ── Trust 自动确认
    let trustConfirmed = false
    let allOutputClean = ''
    const TRUST_RE = /trust[\s\S]*directory|Yes,?\s*I?\s*trust|Enter\s*to\s*confirm|Entertoconfirm|Press\s*enter\s*to\s*continue/i

    // [H4] 防止 error + exit 双重触发
    let ended = false

    const onData = (data: Buffer) => {
      // Trust 检测
      if (!trustConfirmed) {
        const chunk = stripAnsi(data.toString('utf-8'))
        allOutputClean += chunk
        // [H2] 限制 buffer 大小
        if (allOutputClean.length > 10000) {
          allOutputClean = allOutputClean.slice(-5000)
        }
        if (TRUST_RE.test(allOutputClean)) {
          trustConfirmed = true
          allOutputClean = '' // 释放内存
          console.log(`[session] ${id} auto-confirming trust`)
          setTimeout(() => proc.stdin?.write(CR), 500)
        }
      }

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

    // [H4] 统一退出处理
    const onEnd = (code: number) => {
      if (ended) return
      ended = true
      clearTimers()
      flushRaw()   // [H6] error 路径也 flush
      flushText()
      this.emit('ended', id, code)
      this.sessions.delete(id)
    }

    proc.on('exit', (code) => {
      console.log(`[session] ${id} exited (code: ${code})`)
      onEnd(code ?? 1)
    })

    proc.on('error', (err) => {
      console.error(`[session] ${id} error:`, err.message)
      onEnd(1)
    })

    const session: Session & { proc: ChildProcess } = {
      id,
      config,
      status: 'running',
      startedAt,
      proc,
      write: (d) => proc.stdin?.write(d),
      writeBinary: (d) => proc.stdin?.write(d),
      resize: () => {},
      approve() {
        proc.stdin?.write('y' + CR)
        this.status = 'running'
      },
      deny() {
        proc.stdin?.write('n' + CR)
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
