import 'dotenv/config'
import { SessionManager } from './core/session.js'
import { startAppServer } from './app-server.js'
import { startDiscordBot } from './discord-bot.js'

const WS_PORT = parseInt(process.env.WS_PORT ?? '3001')
const AUTH_TOKEN = process.env.AUTH_TOKEN

if (!AUTH_TOKEN || AUTH_TOKEN === 'changeme') {
  console.error('ERROR: Set a strong AUTH_TOKEN in .env')
  process.exit(1)
}

const sessions = new SessionManager()

// App WS Server (always starts)
startAppServer(sessions, WS_PORT, AUTH_TOKEN)

// Discord Bot (optional, gracefully degrade if fails)
try {
  await startDiscordBot(sessions)
} catch (e) {
  console.warn(`[discord] Failed to start: ${(e as Error).message}`)
  console.warn('[discord] App WS server is still running.')
}

process.on('SIGINT', () => {
  console.log('\nShutting down...')
  sessions.killAll()
  // 给 PTY 进程 500ms 清理时间
  setTimeout(() => process.exit(0), 500)
})

console.log('cli-relay ready.')
