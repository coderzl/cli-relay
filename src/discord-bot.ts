import {
  ActionRowBuilder,
  AttachmentBuilder,
  ButtonBuilder,
  ButtonStyle,
  Client,
  EmbedBuilder,
  GatewayIntentBits,
  Interaction,
  Message,
  REST,
  Routes,
  SlashCommandBuilder,
  TextChannel,
  ThreadAutoArchiveDuration,
  ThreadChannel,
} from 'discord.js'
import { SessionManager } from './core/session.js'
import type { SessionInfo, ApprovalMatch } from './core/types.js'

// ── 颜色常量 (iOS palette) ──────────────────────────────

const C = {
  blue:   0x007AFF,
  green:  0x34C759,
  orange: 0xFF9500,
  red:    0xFF3B30,
  gray:   0x8E8E93,
  purple: 0xAF52DE,
} as const

// ── 语法检测 ─────────────────────────────────────────────

function detectLang(text: string): string {
  if (/^diff\s|^[-+]{3}\s|^@@\s/m.test(text)) return 'diff'
  if (/^\s*(import|from|def |class |async def)/m.test(text)) return 'python'
  if (/^\s*(import|export|const |let |function |=>)/m.test(text)) return 'typescript'
  if (/^\s*(func |package |type .*struct)/m.test(text)) return 'go'
  if (/^\s*(fn |let mut |use |impl |pub )/m.test(text)) return 'rust'
  if (/^\s*(\$|#.*bash|echo |cd |mkdir |rm )/m.test(text)) return 'bash'
  if (/[{}();]/.test(text)) return 'javascript'
  return ''
}

function isCodeBlock(text: string): boolean {
  const lines = text.split('\n')
  const codeLines = lines.filter(
    (l) => /^\s{2,}/.test(l) || /[{}();\[\]=><]/.test(l) || /^\s*(\/\/|#|--|\/\*)/.test(l)
  )
  return codeLines.length > lines.length * 0.4
}

// ── 输出格式化 ───────────────────────────────────────────

const MAX_EMBED = 4000
const MAX_FIELD = 1024

function formatOutput(text: string): EmbedBuilder[] {
  const embeds: EmbedBuilder[] = []

  // 短输出: 单个 embed
  if (text.length <= MAX_EMBED) {
    const lang = isCodeBlock(text) ? detectLang(text) : ''
    const content = lang
      ? `\`\`\`${lang}\n${text}\n\`\`\``
      : `\`\`\`\n${text}\n\`\`\``

    embeds.push(
      new EmbedBuilder()
        .setColor(C.green)
        .setDescription(content.slice(0, MAX_EMBED))
    )
    return embeds
  }

  // 长输出: 拆分为多个 embed
  const chunks = smartChunk(text, MAX_EMBED - 20)
  for (let i = 0; i < chunks.length; i++) {
    const lang = isCodeBlock(chunks[i]) ? detectLang(chunks[i]) : ''
    embeds.push(
      new EmbedBuilder()
        .setColor(C.green)
        .setDescription(`\`\`\`${lang}\n${chunks[i]}\n\`\`\``)
        .setFooter(chunks.length > 1 ? { text: `Part ${i + 1}/${chunks.length}` } : null)
    )
  }
  return embeds
}

function smartChunk(text: string, max: number): string[] {
  const parts: string[] = []
  while (text.length > 0) {
    if (text.length <= max) { parts.push(text); break }
    // 优先在空行处分割
    let cut = text.lastIndexOf('\n\n', max)
    if (cut < max * 0.3) cut = text.lastIndexOf('\n', max)
    if (cut <= 0) cut = max
    parts.push(text.slice(0, cut))
    text = text.slice(cut + 1)
  }
  return parts
}

// ── Slash Commands ──────────────────────────────────────

function slashCommands() {
  return [
    new SlashCommandBuilder()
      .setName('run')
      .setDescription('Start an AI agent session')
      .addStringOption((o) =>
        o.setName('agent').setDescription('Agent').setRequired(true)
          .addChoices(
            { name: 'claude', value: 'claude' },
            { name: 'codex', value: 'codex' },
            { name: 'qoder', value: 'qoder' },
            { name: 'custom', value: 'custom' },
          )
      )
      .addStringOption((o) =>
        o.setName('prompt').setDescription('Prompt').setRequired(true)
      )
      .addStringOption((o) =>
        o.setName('workdir').setDescription('Working directory')
      )
      .addBooleanOption((o) =>
        o.setName('yolo').setDescription('YOLO mode — auto-approve all')
      )
      .addStringOption((o) =>
        o.setName('cmd').setDescription('Custom command / alias (for agent=custom)')
      )
      .toJSON(),
    new SlashCommandBuilder()
      .setName('sessions').setDescription('List active sessions').toJSON(),
    new SlashCommandBuilder()
      .setName('killall').setDescription('Kill all sessions').toJSON(),
  ]
}

// ── 按钮组件 ─────────────────────────────────────────────

function approvalRow(sid: string) {
  return new ActionRowBuilder<ButtonBuilder>().addComponents(
    new ButtonBuilder().setCustomId(`approve:${sid}`).setLabel('Approve').setEmoji('✅').setStyle(ButtonStyle.Success),
    new ButtonBuilder().setCustomId(`deny:${sid}`).setLabel('Deny').setEmoji('❌').setStyle(ButtonStyle.Danger),
    new ButtonBuilder().setCustomId(`stop:${sid}`).setLabel('Stop').setEmoji('⏹').setStyle(ButtonStyle.Secondary),
  )
}

// ── 消息编辑管理器 ───────────────────────────────────────
// 不断编辑同一条消息直到满，减少消息刷屏

class MessageEditor {
  private current: Message | null = null
  private content = ''
  private thread: ThreadChannel
  private lang = ''
  private sending = false
  private pendingText = ''

  constructor(thread: ThreadChannel) {
    this.thread = thread
  }

  async append(text: string, sid: string) {
    // 累积待发文本
    this.pendingText += (this.pendingText ? '\n' : '') + text

    if (this.sending) return // 正在发送中，等下一轮
    this.sending = true

    while (this.pendingText) {
      const toSend = this.pendingText
      this.pendingText = ''

      try {
        const newContent = this.content + (this.content ? '\n' : '') + toSend
        const lang = detectLang(newContent) || this.lang
        this.lang = lang

        const formatted = `\`\`\`${lang}\n${newContent}\n\`\`\``

        if (formatted.length < 1900 && this.current) {
          // 编辑现有消息
          this.content = newContent
          await this.current.edit({
            content: formatted,
            components: [approvalRow(sid)],
          })
        } else if (formatted.length < 1900 && !this.current) {
          // 创建新消息
          this.content = newContent
          this.current = await this.thread.send({
            content: formatted,
            components: [approvalRow(sid)],
          })
        } else {
          // 消息满了，finalize 当前消息并开新消息
          this.current = null
          this.content = toSend
          const newLang = detectLang(toSend)
          const newFormatted = `\`\`\`${newLang}\n${toSend}\n\`\`\``

          if (newFormatted.length > 1900) {
            // 超长单块: 发文件附件
            const file = new AttachmentBuilder(
              Buffer.from(toSend, 'utf-8'),
              { name: 'output.txt' }
            )
            const preview = toSend.slice(0, 300) + '...'
            this.current = await this.thread.send({
              content: `\`\`\`\n${preview}\n\`\`\``,
              files: [file],
              components: [approvalRow(sid)],
            })
            this.content = ''
          } else {
            this.current = await this.thread.send({
              content: newFormatted,
              components: [approvalRow(sid)],
            })
          }
        }
      } catch (e) {
        console.error('[discord] message error:', e)
      }
    }

    this.sending = false
  }

  reset() {
    this.current = null
    this.content = ''
    this.lang = ''
  }
}

// ── 启动 Bot ─────────────────────────────────────────────

export async function startDiscordBot(sessions: SessionManager) {
  const { DISCORD_TOKEN, DISCORD_APP_ID, OWNER_ID } = process.env
  if (!DISCORD_TOKEN || !DISCORD_APP_ID || !OWNER_ID) {
    console.log('[discord] Not configured, skipping.')
    return null
  }

  const client = new Client({
    intents: [
      GatewayIntentBits.Guilds,
      GatewayIntentBits.GuildMessages,
      GatewayIntentBits.MessageContent,
    ],
  })

  // sid → { threadId, editor }
  const live = new Map<string, { threadId: string; editor: MessageEditor }>()

  // ── 事件: processed 输出 → Discord ──────────────────

  sessions.on('processed', (sid: string, text: string, isLong: boolean) => {
    const entry = live.get(sid)
    if (!entry) return
    entry.editor.append(text, sid)
  })

  sessions.on('approval', (sid: string, match: ApprovalMatch) => {
    const entry = live.get(sid)
    if (!entry) return
    const thread = client.channels.cache.get(entry.threadId) as ThreadChannel
    if (!thread) return

    const embed = new EmbedBuilder()
      .setColor(C.orange)
      .setTitle('⚠️ Permission Required')
      .setDescription(`\`\`\`\n${match.description.slice(0, 3900)}\n\`\`\``)
      .setTimestamp()

    thread.send({
      embeds: [embed],
      components: [approvalRow(sid)],
    }).catch(console.error)

    // 新审批 → 开新消息块
    entry.editor.reset()
  })

  sessions.on('ended', (sid: string, exitCode: number) => {
    const entry = live.get(sid)
    if (!entry) return
    const thread = client.channels.cache.get(entry.threadId) as ThreadChannel
    if (!thread) return

    const color = exitCode === 0 ? C.green : C.red
    const emoji = exitCode === 0 ? '✅' : '❌'
    const embed = new EmbedBuilder()
      .setColor(color)
      .setDescription(`${emoji} Session ended (exit: ${exitCode})`)
      .setTimestamp()

    thread.send({ embeds: [embed] }).catch(console.error)

    // 更新线程名
    thread.setName(`${emoji} ${thread.name.replace(/^[🟢🔴✅❌⚡]\s*/, '')}`).catch(() => {})
    live.delete(sid)
  })

  // ── 交互处理 ──────────────────────────────────────────

  client.on('interactionCreate', async (interaction: Interaction) => {
    if (interaction.user.id !== OWNER_ID) {
      if (interaction.isRepliable())
        await interaction.reply({ content: '⛔', ephemeral: true })
      return
    }

    // 按钮
    if (interaction.isButton()) {
      const [action, sid] = interaction.customId.split(':')
      const s = sessions.get(sid)
      if (!s) {
        await interaction.reply({ content: 'Session gone', ephemeral: true })
        return
      }
      if (action === 'approve') s.approve()
      else if (action === 'deny') s.deny()
      else if (action === 'stop') s.kill()
      await interaction.deferUpdate()
      return
    }

    if (!interaction.isChatInputCommand()) return

    // /sessions
    if (interaction.commandName === 'sessions') {
      const list = sessions.list()
      if (!list.length) {
        await interaction.reply({ content: 'No active sessions.', ephemeral: true })
        return
      }
      const embed = new EmbedBuilder()
        .setColor(C.blue)
        .setTitle('Active Sessions')
        .setDescription(
          list
            .map((s) => {
              const yTag = s.yolo ? ' `YOLO`' : ''
              const dur = Math.round((Date.now() - s.startedAt) / 1000)
              return `**${s.agent}** \`${s.id}\`${yTag} — \`${s.workDir}\` — ${dur}s`
            })
            .join('\n')
        )
      await interaction.reply({ embeds: [embed], ephemeral: true })
      return
    }

    // /killall
    if (interaction.commandName === 'killall') {
      const count = sessions.list().length
      sessions.killAll()
      live.clear()
      await interaction.reply({ content: `Killed ${count} sessions.`, ephemeral: true })
      return
    }

    // /run
    if (interaction.commandName === 'run') {
      const agent = interaction.options.getString('agent', true) as any
      const prompt = interaction.options.getString('prompt', true)
      const workDir = interaction.options.getString('workdir') ?? process.env.WORK_DIR ?? process.env.HOME!
      const yolo = interaction.options.getBoolean('yolo') ?? false
      const customCmd = interaction.options.getString('cmd') ?? undefined

      const yTag = yolo ? ' `YOLO`' : ''
      const cmdTag = customCmd ? ` via \`${customCmd}\`` : ''

      const startEmbed = new EmbedBuilder()
        .setColor(C.purple)
        .setDescription(`⚡ Starting **${agent}**${yTag}${cmdTag}\n📂 \`${workDir}\``)

      await interaction.reply({ embeds: [startEmbed] })

      const channel = interaction.channel as TextChannel
      const thread = await channel.threads.create({
        name: `🟢 ${agent}: ${prompt.slice(0, 80)}`,
        autoArchiveDuration: ThreadAutoArchiveDuration.OneHour,
      })

      const editor = new MessageEditor(thread)
      const session = sessions.start({ agent, prompt, workDir, yolo, customCmd })
      live.set(session.id, { threadId: thread.id, editor })

      const infoEmbed = new EmbedBuilder()
        .setColor(C.blue)
        .setDescription(
          `Session \`${session.id}\` — type here to send input.\n` +
          `Agent: **${agent}**${yTag} | Dir: \`${workDir}\``
        )
        .setFooter({ text: 'Messages in this thread → stdin' })

      await thread.send({
        embeds: [infoEmbed],
        components: [approvalRow(session.id)],
      })
    }
  })

  // 线程文字 → stdin
  client.on('messageCreate', (msg) => {
    if (msg.author.bot || msg.author.id !== OWNER_ID) return
    for (const [sid, entry] of live) {
      if (entry.threadId === msg.channelId) {
        sessions.get(sid)?.write(msg.content + '\r') // PTY raw mode 需要 CR
        // 新输入后 → 开新消息块
        entry.editor.reset()
        break
      }
    }
  })

  // ── 注册 & 登录 ──────────────────────────────────────

  const rest = new REST().setToken(DISCORD_TOKEN)
  await rest.put(Routes.applicationCommands(DISCORD_APP_ID), { body: slashCommands() })

  client.once('ready', () => console.log(`[discord] Online: ${client.user?.tag}`))
  await client.login(DISCORD_TOKEN)
  return client
}
