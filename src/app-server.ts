import { WebSocketServer, WebSocket } from 'ws'
import type { IncomingMessage } from 'node:http'
import { SessionManager, safeTokenEqual } from './core/session.js'
import type { AppClientMsg, AppServerMsg, SessionInfo, ApprovalMatch } from './core/types.js'

// [C1+C3] Agent 白名单（与 session.ts 保持一致）
const VALID_AGENTS = ['claude', 'codex', 'qoder', 'custom']

export function startAppServer(
  sessions: SessionManager,
  port: number,
  token: string,
) {
  // [M9] 限制消息大小 1MB
  const wss = new WebSocketServer({ port, maxPayload: 1024 * 1024 })

  wss.on('error', (err) => {
    console.error(`[app-ws] Server error: ${err.message}`)
  })

  const clients = new Set<WebSocket>()

  function send(ws: WebSocket, msg: AppServerMsg) {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg))
  }

  function broadcast(msg: AppServerMsg) {
    const data = JSON.stringify(msg)
    for (const ws of clients) {
      if (ws.readyState === WebSocket.OPEN) ws.send(data)
    }
  }

  // ── Session 事件 → 广播

  sessions.on('raw', (sid: string, buf: Buffer) => {
    broadcast({ t: 'data', sid, d: buf.toString('base64') })
  })

  sessions.on('started', (sid: string, info: SessionInfo) => {
    broadcast({ t: 'started', sid, agent: info.agent, workDir: info.workDir })
  })

  sessions.on('approval', (sid: string, match: ApprovalMatch) => {
    broadcast({ t: 'approval', sid, tool: match.tool, desc: match.description })
  })

  sessions.on('ended', (sid: string, code: number) => {
    broadcast({ t: 'ended', sid, code })
  })

  // ── 输入验证 [C3] 加 agent 白名单

  function validateStart(c: unknown): boolean {
    if (!c || typeof c !== 'object') return false
    const obj = c as Record<string, unknown>
    return typeof obj.agent === 'string' &&
           VALID_AGENTS.includes(obj.agent as string) && // [C3]
           typeof obj.prompt === 'string' &&
           typeof obj.workDir === 'string' &&
           typeof obj.yolo === 'boolean'
  }

  // ── [M3] 简易速率限制
  const msgCounts = new WeakMap<WebSocket, { count: number; resetAt: number }>()
  function rateLimit(ws: WebSocket): boolean {
    const now = Date.now()
    let entry = msgCounts.get(ws)
    if (!entry || now > entry.resetAt) {
      entry = { count: 0, resetAt: now + 1000 }
      msgCounts.set(ws, entry)
    }
    entry.count++
    return entry.count > 50 // 50 msg/s
  }

  // ── 客户端连接

  wss.on('connection', (ws: WebSocket, req: IncomingMessage) => {
    const url = new URL(req.url ?? '/', `http://${req.headers.host}`)
    const clientToken = url.searchParams.get('token') ?? ''

    // [C2] 时序安全的 token 比较
    if (!safeTokenEqual(clientToken, token)) {
      ws.close(4001, 'Unauthorized')
      return
    }

    clients.add(ws)
    console.log(`[app-ws] +1 client (${clients.size})`)

    // Ping 保活 (每 10 秒)
    const pingInterval = setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) ws.ping()
    }, 10000)

    // 推送当前会话列表
    send(ws, { t: 'list', sessions: sessions.list() })

    ws.on('message', (raw) => {
      // [M3] 速率限制
      if (rateLimit(ws)) {
        send(ws, { t: 'error', msg: 'Rate limited' })
        return
      }

      try {
        const msg = JSON.parse(raw.toString()) as AppClientMsg
        if (!msg || typeof msg.t !== 'string') {
          send(ws, { t: 'error', msg: 'Missing message type' })
          return
        }

        switch (msg.t) {
          case 'start': {
            if (!validateStart(msg.c)) {
              send(ws, { t: 'error', msg: 'Invalid session config' })
              return
            }
            try {
              sessions.start(msg.c)
            } catch (e) {
              send(ws, { t: 'error', msg: (e as Error).message })
            }
            break
          }

          case 'input':
            if (typeof msg.sid === 'string' && typeof msg.d === 'string')
              sessions.get(msg.sid)?.write(msg.d)
            break

          case 'resize':
            if (typeof msg.sid === 'string')
              sessions.get(msg.sid)?.resize(msg.cols ?? 0, msg.rows ?? 0)
            break

          case 'approve':
            if (typeof msg.sid === 'string') sessions.get(msg.sid)?.approve()
            break

          case 'deny':
            if (typeof msg.sid === 'string') sessions.get(msg.sid)?.deny()
            break

          case 'stop':
            if (typeof msg.sid === 'string') sessions.get(msg.sid)?.kill()
            break

          case 'list':
            send(ws, { t: 'list', sessions: sessions.list() })
            break
        }
      } catch {
        send(ws, { t: 'error', msg: 'Invalid message' })
      }
    })

    ws.on('close', () => {
      clearInterval(pingInterval)
      clients.delete(ws)
      console.log(`[app-ws] -1 client (${clients.size})`)
    })

    ws.on('error', (err) => {
      console.error(`[app-ws] Client error: ${err.message}`)
    })
  })

  console.log(`[app-ws] Listening on :${port}`)
  return wss
}
