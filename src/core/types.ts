// ── 会话配置 ─────────────────────────────────────────────

export interface SessionConfig {
  agent: 'claude' | 'codex' | 'qoder' | 'custom'
  prompt: string
  workDir: string
  yolo: boolean
  /** 自定义启动命令，如 zsh alias 或脚本路径。
   *  设置后忽略 agent 字段，直接用此命令启动。
   *  示例: "my-claude" (alias), "/path/to/run.sh", "zsh -ic 'my-alias'" */
  customCmd?: string
}

export interface SessionInfo {
  id: string
  agent: string
  workDir: string
  yolo: boolean
  status: 'running' | 'waiting_approval'
  startedAt: number
}

// ── App WS 协议（原始终端流）─────────────────────────────

export type AppClientMsg =
  | { t: 'start'; c: SessionConfig }
  | { t: 'input'; sid: string; d: string }     // raw stdin
  | { t: 'resize'; sid: string; cols: number; rows: number }
  | { t: 'approve'; sid: string }
  | { t: 'deny'; sid: string }
  | { t: 'stop'; sid: string }
  | { t: 'list' }

export type AppServerMsg =
  | { t: 'started'; sid: string; agent: string; workDir: string }
  | { t: 'data'; sid: string; d: string }       // raw PTY output (base64)
  | { t: 'approval'; sid: string; tool: string; desc: string }
  | { t: 'ended'; sid: string; code: number }
  | { t: 'list'; sessions: SessionInfo[] }
  | { t: 'error'; msg: string }

// ── 审批检测结果 ─────────────────────────────────────────

export interface ApprovalMatch {
  tool: string
  description: string
  rawContext: string
}
