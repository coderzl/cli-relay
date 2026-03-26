import { WebSocketServer, WebSocket } from 'ws'
import type { IncomingMessage } from 'node:http'
import { SessionManager, safeTokenEqual } from './core/session.js'
import type { AppClientMsg, AppServerMsg, SessionInfo, ApprovalMatch } from './core/types.js'

const VALID_AGENTS = ['claude', 'codex', 'qoder', 'custom']

export function startAppServer(
  sessions: SessionManager,
  port: number,
  token: string,
) {
  const wss = new WebSocketServer({ port, maxPayload: 1024 * 1024 })

  wss.on('error', (err) => {
    console.error(`[app-ws] Server error: ${err.message}`)
  })

  const clients = new Set<WebSocket>()
  const defaultWorkDir = process.env.WORK_DIR ?? process.env.HOME ?? '/'

  function send(ws: WebSocket, msg: AppServerMsg) {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg))
  }

  function broadcast(msg: AppServerMsg) {
    let data: string
    try {
      data = JSON.stringify(msg)
    } catch (e) {
      console.error(`[app-ws] Serialize error: ${e}`)
      return
    }
    for (const ws of clients) {
      if (ws.readyState === WebSocket.OPEN) {
        try { ws.send(data) } catch {}
      }
    }
  }

  // ── Session 事件 → 广播

  sessions.on('raw', (sid: string, buf: Buffer) => {
    broadcast({ t: 'data', sid, d: buf.toString('base64') })
  })

  sessions.on('started', (sid: string, info: SessionInfo) => {
    broadcast({ t: 'started', sid, session: info })
  })

  sessions.on('approval', (sid: string, match: ApprovalMatch) => {
    broadcast({ t: 'approval', sid, tool: match.tool, desc: match.description })
  })

  sessions.on('ended', (sid: string, code: number) => {
    broadcast({ t: 'ended', sid, code })
  })

  // ── 输入验证

  function validateStart(c: unknown): boolean {
    if (!c || typeof c !== 'object') return false
    const obj = c as Record<string, unknown>
    return typeof obj.agent === 'string' &&
           VALID_AGENTS.includes(obj.agent as string) &&
           typeof obj.prompt === 'string' &&
           typeof obj.workDir === 'string' &&
           typeof obj.yolo === 'boolean'
  }

  // ── 速率限制
  const msgCounts = new WeakMap<WebSocket, { count: number; resetAt: number }>()
  function rateLimit(ws: WebSocket): boolean {
    const now = Date.now()
    let entry = msgCounts.get(ws)
    if (!entry || now > entry.resetAt) {
      entry = { count: 0, resetAt: now + 1000 }
      msgCounts.set(ws, entry)
    }
    entry.count++
    return entry.count > 50
  }

  // ── 客户端连接

  wss.on('connection', (ws: WebSocket, req: IncomingMessage) => {
    const url = new URL(req.url ?? '/', `http://${req.headers.host}`)
    const clientToken = url.searchParams.get('token') ?? ''

    if (!safeTokenEqual(clientToken, token)) {
      ws.close(4001, 'Unauthorized')
      return
    }

    clients.add(ws)
    console.log(`[app-ws] +1 client (${clients.size})`)

    const pingInterval = setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) ws.ping()
    }, 10000)

    // 推送当前会话列表 + 服务端配置
    send(ws, {
      t: 'list',
      sessions: sessions.list(),
      config: { defaultWorkDir },
    })

    ws.on('message', (raw) => {
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
            const reqId = msg.reqId
            if (!reqId || typeof reqId !== 'string') {
              send(ws, { t: 'error', msg: 'Missing reqId' })
              return
            }
            if (!validateStart(msg.c)) {
              send(ws, { t: 'start_ack', reqId, result: 'error', msg: 'Invalid session config' })
              return
            }
            try {
              const session = sessions.start(msg.c, 'app', msg.clientId)
              send(ws, { t: 'start_ack', reqId, result: 'ok', session: session.info() })
            } catch (e) {
              send(ws, { t: 'start_ack', reqId, result: 'error', msg: (e as Error).message })
            }
            break
          }

          case 'input':
            if (typeof msg.sid === 'string' && typeof msg.d === 'string') {
              if (msg.d.length > 10000) {
                send(ws, { t: 'error', msg: 'Input too large' })
                return
              }
              sessions.get(msg.sid)?.write(msg.d)
            }
            break

          case 'resize':
            if (typeof msg.sid === 'string' &&
                typeof msg.cols === 'number' && msg.cols > 0 && msg.cols <= 1000 &&
                typeof msg.rows === 'number' && msg.rows > 0 && msg.rows <= 1000) {
              sessions.get(msg.sid)?.resize(msg.cols, msg.rows)
            }
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
            send(ws, {
              t: 'list',
              sessions: sessions.list(),
              config: { defaultWorkDir },
            })
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
