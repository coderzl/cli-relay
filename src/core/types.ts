// ── 会话配置 ─────────────────────────────────────────────

export interface SessionConfig {
  agent: 'claude' | 'codex' | 'qoder' | 'custom'
  prompt: string
  workDir: string
  yolo: boolean
  /** 自定义启动命令（仅 agent=custom 时使用）。
   *  必须匹配 SAFE_CMD_RE，禁止 shell 注入。 */
  customCmd?: string
}

export interface SessionInfo {
  id: string
  agent: string
  workDir: string
  yolo: boolean
  status: 'starting' | 'running' | 'waiting_approval' | 'ended' | 'failed'
  startedAt: number
  source: 'app' | 'discord'
  initiatorClientId?: string
  exitCode?: number | null
}

// ── App WS 协议 ─────────────────────────────────────────

export type AppClientMsg =
  | { t: 'start'; reqId: string; c: SessionConfig; source?: 'app'; clientId?: string }
  | { t: 'input'; sid: string; d: string }
  | { t: 'resize'; sid: string; cols: number; rows: number }
  | { t: 'approve'; sid: string }
  | { t: 'deny'; sid: string }
  | { t: 'stop'; sid: string }
  | { t: 'list' }

export type AppServerMsg =
  | { t: 'start_ack'; reqId: string; result: 'ok'; session: SessionInfo }
  | { t: 'start_ack'; reqId: string; result: 'error'; msg: string }
  | { t: 'started'; sid: string; session: SessionInfo }
  | { t: 'data'; sid: string; d: string }
  | { t: 'approval'; sid: string; tool: string; desc: string }
  | { t: 'ended'; sid: string; code: number }
  | { t: 'list'; sessions: SessionInfo[]; config?: { defaultWorkDir: string } }
  | { t: 'error'; msg: string }

// ── 审批检测结果 ─────────────────────────────────────────

export interface ApprovalMatch {
  tool: string
  description: string
  rawContext: string
}
