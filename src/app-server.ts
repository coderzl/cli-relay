import { WebSocketServer, WebSocket } from 'ws'
import type { IncomingMessage } from 'node:http'
import { SessionManager } from './core/session.js'
import type { AppClientMsg, AppServerMsg, SessionInfo, ApprovalMatch } from './core/types.js'

export function startAppServer(
  sessions: SessionManager,
  port: number,
  token: string,
) {
  const wss = new WebSocketServer({ port })
  const clients = new Set<WebSocket>()

  wss.on('error', (err) => {
    console.error(`[app-ws] Server error: ${err.message}`)
  })

  function send(ws: WebSocket, msg: AppServerMsg) {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg))
  }

  function broadcast(msg: AppServerMsg) {
    const data = JSON.stringify(msg)
    for (const ws of clients) {
      if (ws.readyState === WebSocket.OPEN) ws.send(data)
    }
  }

  // ── 输出缓存: 重连后重放，保证不丢输出 ─────────────────

  const outputHistory = new Map<string, string[]>() // sid → base64 chunks
  const MAX_HISTORY = 200 // 每个 session 最多缓存 200 条

  // ── Session 事件 → 广播 + 缓存 ────────────────────────

  sessions.on('raw', (sid: string, buf: Buffer) => {
    const b64 = buf.toString('base64')
    // 缓存
    if (!outputHistory.has(sid)) outputHistory.set(sid, [])
    const hist = outputHistory.get(sid)!
    hist.push(b64)
    if (hist.length > MAX_HISTORY) hist.shift()
    // 广播
    broadcast({ t: 'data', sid, d: b64 })
  })

  sessions.on('started', (sid: string, info: SessionInfo) => {
    outputHistory.set(sid, [])
    broadcast({ t: 'started', sid, agent: info.agent, workDir: info.workDir })
  })

  sessions.on('approval', (sid: string, match: ApprovalMatch) => {
    broadcast({ t: 'approval', sid, tool: match.tool, desc: match.description })
  })

  sessions.on('ended', (sid: string, code: number) => {
    broadcast({ t: 'ended', sid, code })
    // 保留历史 5 分钟供回看
    setTimeout(() => outputHistory.delete(sid), 5 * 60 * 1000)
  })

  // ── 输入验证 ──────────────────────────────────────────

  function validateStart(c: unknown): boolean {
    if (!c || typeof c !== 'object') return false
    const obj = c as Record<string, unknown>
    return typeof obj.agent === 'string' &&
           typeof obj.prompt === 'string' &&
           typeof obj.workDir === 'string' &&
           typeof obj.yolo === 'boolean'
  }

  // ── 客户端连接 ────────────────────────────────────────

  wss.on('connection', (ws: WebSocket, req: IncomingMessage) => {
    const url = new URL(req.url ?? '/', `http://${req.headers.host}`)
    if (url.searchParams.get('token') !== token) {
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

    // 重连时重放所有活跃 session 的输出历史
    for (const info of sessions.list()) {
      send(ws, { t: 'started', sid: info.id, agent: info.agent, workDir: info.workDir })
      const hist = outputHistory.get(info.id) ?? []
      for (const d of hist) {
        send(ws, { t: 'data', sid: info.id, d })
      }
    }

    ws.on('message', (raw) => {
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
