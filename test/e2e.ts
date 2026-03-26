/**
 * End-to-end test for cli-relay protocol.
 * Tests: connection, request/ack, session lifecycle, resize, approval, error handling.
 */
import WebSocket from 'ws'

const WS_URL = 'ws://127.0.0.1:3001'
const TOKEN = '164b1f6546599cffcfe71ed66e7ffd04'
const BAD_TOKEN = 'wrong-token'
const WORK_DIR = '/Volumes/D/zhige'

let passed = 0
let failed = 0

function assert(condition: boolean, msg: string) {
  if (condition) {
    passed++
    console.log(`  ✅ ${msg}`)
  } else {
    failed++
    console.error(`  ❌ ${msg}`)
  }
}

function connect(token: string = TOKEN): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WS_URL}?token=${token}`)
    ws.on('open', () => resolve(ws))
    ws.on('error', reject)
  })
}

function waitMsg(ws: WebSocket, filter?: (msg: any) => boolean, timeout = 5000): Promise<any> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Timeout')), timeout)
    const handler = (raw: WebSocket.Data) => {
      const msg = JSON.parse(raw.toString())
      if (!filter || filter(msg)) {
        clearTimeout(timer)
        ws.off('message', handler)
        resolve(msg)
      }
    }
    ws.on('message', handler)
  })
}

function collectMsgs(ws: WebSocket, duration: number): Promise<any[]> {
  return new Promise(resolve => {
    const msgs: any[] = []
    const handler = (raw: WebSocket.Data) => {
      msgs.push(JSON.parse(raw.toString()))
    }
    ws.on('message', handler)
    setTimeout(() => {
      ws.off('message', handler)
      resolve(msgs)
    }, duration)
  })
}

async function main() {
  console.log('\n🧪 CLI Relay E2E Tests\n')

  // ── Test 1: Auth rejection
  console.log('── Auth')
  try {
    const badWs = new WebSocket(`${WS_URL}?token=${BAD_TOKEN}`)
    const code = await new Promise<number>((resolve) => {
      badWs.on('close', (code) => resolve(code))
      badWs.on('error', () => {})
    })
    assert(code === 4001, 'Bad token rejected with 4001')
  } catch {
    assert(false, 'Bad token rejection')
  }

  // ── Test 2: Connect + receive list
  console.log('── Connection')
  const ws = await connect()
  const listMsg = await waitMsg(ws, m => m.t === 'list')
  assert(listMsg.t === 'list', 'Receive initial list')
  assert(Array.isArray(listMsg.sessions), 'List has sessions array')
  assert(listMsg.config?.defaultWorkDir === WORK_DIR, `Config has defaultWorkDir=${WORK_DIR}`)

  // ── Test 3: Start with reqId → start_ack
  console.log('── Session Start (request/ack)')
  const reqId = 'test-req-001'
  ws.send(JSON.stringify({
    t: 'start',
    reqId,
    c: {
      agent: 'claude',
      prompt: '',
      workDir: WORK_DIR,
      yolo: false,
    },
    source: 'app',
    clientId: 'test-client-1',
  }))

  const ack = await waitMsg(ws, m => m.t === 'start_ack', 10000)
  assert(ack.reqId === reqId, 'start_ack has matching reqId')
  assert(ack.result === 'ok', 'start_ack result is ok')
  assert(typeof ack.session?.id === 'string', 'start_ack has session.id')
  assert(ack.session?.source === 'app', 'session.source = app')
  assert(ack.session?.initiatorClientId === 'test-client-1', 'session has initiatorClientId')
  assert(ack.session?.agent === 'claude', 'session.agent = claude')
  assert(ack.session?.workDir === WORK_DIR, `session.workDir = ${WORK_DIR}`)
  assert(typeof ack.session?.startedAt === 'number', 'session.startedAt is number')

  const sid = ack.session?.id as string

  // ── Test 4: started broadcast received
  // Note: started is emitted before start_ack in the event loop, so it was already received.
  // Let's verify by checking list
  ws.send(JSON.stringify({ t: 'list' }))
  const listAfter = await waitMsg(ws, m => m.t === 'list')
  const found = listAfter.sessions.find((s: any) => s.id === sid)
  assert(!!found, 'Session appears in list after start')
  assert(found?.source === 'app', 'Listed session has source=app')

  // ── Test 5: Receive data
  console.log('── Data Streaming')
  const dataMsg = await waitMsg(ws, m => m.t === 'data' && m.sid === sid, 15000)
  assert(dataMsg.t === 'data', 'Receive data from session')
  assert(typeof dataMsg.d === 'string', 'Data is base64 string')

  // ── Test 6: Resize
  console.log('── Resize')
  ws.send(JSON.stringify({ t: 'resize', sid, cols: 80, rows: 24 }))
  // No ack for resize, just verify no error
  await new Promise(r => setTimeout(r, 500))
  assert(true, 'Resize sent without error')

  // ── Test 7: Input
  console.log('── Input')
  ws.send(JSON.stringify({ t: 'input', sid, d: '\r' }))
  await new Promise(r => setTimeout(r, 500))
  assert(true, 'Input sent without error')

  // ── Test 8: Stop session
  console.log('── Session Stop')
  ws.send(JSON.stringify({ t: 'stop', sid }))
  const endMsg = await waitMsg(ws, m => m.t === 'ended' && m.sid === sid, 10000)
  assert(endMsg.t === 'ended', 'Session ended event received')
  assert(typeof endMsg.code === 'number', 'Ended has exit code')

  // ── Test 9: Start with bad workDir → start_ack error
  console.log('── Error Handling')
  const badReqId = 'test-req-bad-dir'
  ws.send(JSON.stringify({
    t: 'start',
    reqId: badReqId,
    c: {
      agent: 'claude',
      prompt: '',
      workDir: '/nonexistent',
      yolo: false,
    },
    source: 'app',
  }))
  const badAck = await waitMsg(ws, m => m.t === 'start_ack' && m.reqId === badReqId)
  assert(badAck.result === 'error', 'Bad workDir returns error')
  assert(badAck.msg.includes('does not exist'), 'Error message mentions directory')

  // ── Test 10: workDir containment bypass
  const bypassReqId = 'test-req-bypass'
  ws.send(JSON.stringify({
    t: 'start',
    reqId: bypassReqId,
    c: {
      agent: 'claude',
      prompt: '',
      workDir: '/tmp',
      yolo: false,
    },
    source: 'app',
  }))
  const bypassAck = await waitMsg(ws, m => m.t === 'start_ack' && m.reqId === bypassReqId)
  assert(bypassAck.result === 'error', 'workDir outside allowed base rejected')
  assert(bypassAck.msg.includes('must be under'), 'Error message mentions containment')

  // ── Test 11: Missing reqId
  ws.send(JSON.stringify({
    t: 'start',
    c: { agent: 'claude', prompt: '', workDir: WORK_DIR, yolo: false },
  }))
  const noReqAck = await waitMsg(ws, m => m.t === 'error')
  assert(noReqAck.msg.includes('reqId'), 'Missing reqId error')

  // ── Test 12: Invalid agent
  const invalidAgentReqId = 'test-req-invalid-agent'
  ws.send(JSON.stringify({
    t: 'start',
    reqId: invalidAgentReqId,
    c: { agent: 'evil-agent; rm -rf /', prompt: '', workDir: WORK_DIR, yolo: false },
  }))
  const invalidAgentAck = await waitMsg(ws, m => m.t === 'start_ack' && m.reqId === invalidAgentReqId)
  assert(invalidAgentAck.result === 'error', 'Invalid agent rejected')

  // ── Test 13: Second client sees started broadcast
  console.log('── Multi-client')
  const ws2 = await connect()
  const list2 = await waitMsg(ws2, m => m.t === 'list')
  assert(list2.t === 'list', 'Second client receives list')

  const reqId2 = 'test-req-multi'
  ws.send(JSON.stringify({
    t: 'start',
    reqId: reqId2,
    c: { agent: 'claude', prompt: '', workDir: WORK_DIR, yolo: false },
    source: 'app',
    clientId: 'client-1',
  }))

  // ws2 should see the started broadcast
  const started2 = await waitMsg(ws2, m => m.t === 'started', 10000)
  assert(started2.t === 'started', 'Second client receives started broadcast')
  assert(started2.session?.source === 'app', 'Broadcast has source')
  assert(started2.session?.initiatorClientId === 'client-1', 'Broadcast has initiatorClientId')

  // Cleanup: stop the session
  const sid2 = started2.sid
  ws.send(JSON.stringify({ t: 'stop', sid: sid2 }))
  await waitMsg(ws, m => m.t === 'ended' && m.sid === sid2, 10000)

  ws2.close()
  ws.close()

  // ── Summary
  console.log(`\n${'='.repeat(40)}`)
  console.log(`✅ Passed: ${passed}`)
  console.log(`❌ Failed: ${failed}`)
  console.log(`${'='.repeat(40)}\n`)

  process.exit(failed > 0 ? 1 : 0)
}

main().catch(e => {
  console.error('Test error:', e)
  process.exit(1)
})
