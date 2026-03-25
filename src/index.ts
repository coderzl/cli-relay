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

// App WS Server
const wss = startAppServer(sessions, WS_PORT, AUTH_TOKEN)

// Discord Bot (optional)
let discordClient: Awaited<ReturnType<typeof startDiscordBot>> = null
try {
  discordClient = await startDiscordBot(sessions)
} catch (e) {
  console.warn(`[discord] Failed to start: ${(e as Error).message}`)
}

// [L4+B9] 优雅退出：SIGINT + SIGTERM
const shutdown = () => {
  console.log('\nShutting down...')
  sessions.killAll()
  wss.close()
  discordClient?.destroy()
  setTimeout(() => process.exit(0), 500)
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)

console.log('cli-relay ready.')
