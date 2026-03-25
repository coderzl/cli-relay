import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';
import '../models/session.dart';

const _maxEndedHistory = 20;
const _sessionStorageKey = 'relay_sessions';

/// 连接稳定性策略:
/// - 断线不立即通知 UI，有 5 秒缓冲期
/// - 缓冲期内重连成功 → 用户完全无感
/// - 超过缓冲期才显示断线状态
/// - sessions/terminals 在断线期间完整保留
/// - 重连后自动同步状态
class RelayClient extends ChangeNotifier {
  WebSocketChannel? _ch;
  String _url = '';
  String _token = '';

  // ── 连接状态（去抖）────────────────────────────────────
  bool _wsConnected = false;     // 底层 WS 连接状态
  bool _visibleConnected = false; // UI 可见的连接状态（有延迟）
  Timer? _disconnectDebounce;    // 断线去抖定时器
  Timer? _heartbeat;
  Timer? _reconnect;
  int _retries = 0;

  // ── Session 状态 ──────────────────────────────────────
  final Map<String, SessionInfo> sessions = {};
  final Map<String, Terminal> terminals = {};
  final Map<String, ApprovalRequest?> approvals = {};
  final List<String> endedIds = [];

  bool get connected => _visibleConnected;

  // ── 事件回调 ──────────────────────────────────────────
  VoidCallback? onApprovalReceived;
  void Function(String sid)? onSessionStarted;

  // ── 连接 ──────────────────────────────────────────────

  void connect(String url, String token) {
    _reconnect?.cancel();
    _disconnectDebounce?.cancel();
    disconnect();
    _url = url;
    _token = token;
    _retries = 0;
    _doConnect();
  }

  void _doConnect() {
    _reconnect?.cancel();
    if (_url.isEmpty) return;

    try {
      _ch = WebSocketChannel.connect(Uri.parse('$_url?token=$_token'));
      _ch!.stream.listen(
        _onRawMessage,
        onDone: _onWsDrop,
        onError: (_) => _onWsDrop(),
      );
      // 连接发起后立刻请求同步
      _send({'t': 'list'});
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void disconnect() {
    _heartbeat?.cancel();
    _disconnectDebounce?.cancel();
    _ch?.sink.close();
    _ch = null;
    _wsConnected = false;
    _visibleConnected = false;
    notifyListeners();
  }

  /// WS 首次收到数据 = 连接确认
  void _onWsUp() {
    if (_wsConnected) return;
    _wsConnected = true;
    _retries = 0;
    _startHeartbeat();

    // 取消断线去抖（如果有的话），立即恢复 UI 状态
    _disconnectDebounce?.cancel();
    if (!_visibleConnected) {
      _visibleConnected = true;
      notifyListeners();
    }
  }

  /// WS 断线处理（去抖）
  void _onWsDrop() {
    _heartbeat?.cancel();
    _ch = null;
    _wsConnected = false;

    // 不立即通知 UI！给 5 秒缓冲期静默重连
    _disconnectDebounce?.cancel();
    _disconnectDebounce = Timer(const Duration(seconds: 5), () {
      if (!_wsConnected) {
        _visibleConnected = false;
        notifyListeners(); // 5 秒后仍断线才通知 UI
      }
    });

    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_url.isEmpty) return;
    final capped = _retries.clamp(0, 4);
    // 重连间隔：0.5s, 1s, 2s, 4s, 8s (更快重连)
    final delay = Duration(milliseconds: (500 * (1 << capped)).clamp(500, 8000));
    _retries++;
    _reconnect = Timer(delay, () {
      if (!_wsConnected && _url.isNotEmpty) _doConnect();
    });
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    // 每 30 秒心跳（降低频率，减少不必要的消息）
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      _send({'t': 'list'});
    });
  }

  // ── 发送 ──────────────────────────────────────────────

  void _send(Map<String, dynamic> msg) {
    if (_ch == null) return;
    try {
      _ch!.sink.add(jsonEncode(msg));
    } catch (_) {
      // 发送失败不触发 _onWsDrop（让 stream 的 onDone/onError 处理）
    }
  }

  void startSession({
    required String agent,
    required String prompt,
    required String workDir,
    required bool yolo,
    String? customCmd,
  }) {
    _send({
      't': 'start',
      'c': {
        'agent': agent,
        'prompt': prompt,
        'workDir': workDir,
        'yolo': yolo,
        if (customCmd != null && customCmd.isNotEmpty) 'customCmd': customCmd,
      },
    });
  }

  void sendInput(String sid, String data) =>
      _send({'t': 'input', 'sid': sid, 'd': data});

  void resize(String sid, int cols, int rows) =>
      _send({'t': 'resize', 'sid': sid, 'cols': cols, 'rows': rows});

  void approve(String sid) {
    _send({'t': 'approve', 'sid': sid});
    approvals[sid] = null;
    notifyListeners();
  }

  void deny(String sid) {
    _send({'t': 'deny', 'sid': sid});
    approvals[sid] = null;
    notifyListeners();
  }

  void stopSession(String sid) => _send({'t': 'stop', 'sid': sid});
  void refresh() => _send({'t': 'list'});

  void clearEnded(String sid) {
    endedIds.remove(sid);
    terminals.remove(sid);
    approvals.remove(sid);
    notifyListeners();
  }

  Terminal terminalFor(String sid) =>
      terminals.putIfAbsent(sid, () => Terminal(maxLines: 10000));

  // ── Session 持久化 ────────────────────────────────────

  Future<void> saveSessionsLocally() async {
    final prefs = await SharedPreferences.getInstance();
    final data = sessions.values
        .map((s) => {
          return '${s.id}|${s.agent}|${s.workDir}|${s.yolo}|${s.startedAt}';
        })
        .toList();
    await prefs.setStringList(_sessionStorageKey, data);
  }

  Future<void> loadSessionsLocally() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getStringList(_sessionStorageKey) ?? [];
    for (final entry in data) {
      final parts = entry.split('|');
      if (parts.length >= 5) {
        final id = parts[0];
        if (!sessions.containsKey(id)) {
          sessions[id] = SessionInfo(
            id: id,
            agent: parts[1],
            workDir: parts[2],
            yolo: parts[3] == 'true',
            status: 'running',
            startedAt: int.tryParse(parts[4]) ?? 0,
          );
          terminalFor(id);
        }
      }
    }
    notifyListeners();
  }

  // ── 接收 ──────────────────────────────────────────────

  void _onRawMessage(dynamic raw) {
    // 收到任何消息 = WS 确认活着
    _onWsUp();

    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      final t = msg['t'] as String?;
      if (t == null) return;

      switch (t) {
        case 'started':
          final sid = msg['sid'] as String? ?? '';
          if (sid.isEmpty) break;
          sessions[sid] = SessionInfo(
            id: sid,
            agent: msg['agent'] as String? ?? 'unknown',
            workDir: msg['workDir'] as String? ?? '',
            yolo: false,
            status: 'running',
            startedAt: DateTime.now().millisecondsSinceEpoch,
          );
          terminalFor(sid);
          onSessionStarted?.call(sid);
          saveSessionsLocally(); // 持久化
          break;

        case 'data':
          final sid = msg['sid'] as String? ?? '';
          final d = msg['d'] as String?;
          if (sid.isEmpty || d == null) break;
          try {
            final bytes = base64Decode(d);
            terminalFor(sid).write(utf8.decode(bytes, allowMalformed: true));
          } catch (_) {}
          // data 消息不触发 notifyListeners（性能优化，Terminal 自己会刷新）
          return;

        case 'approval':
          final sid = msg['sid'] as String? ?? '';
          if (sid.isEmpty) break;
          approvals[sid] = ApprovalRequest(
            sessionId: sid,
            tool: msg['tool'] as String? ?? 'tool',
            description: msg['desc'] as String? ?? '',
          );
          onApprovalReceived?.call();
          break;

        case 'ended':
          final sid = msg['sid'] as String? ?? '';
          if (sid.isEmpty) break;
          sessions.remove(sid);
          approvals.remove(sid);
          if (terminals.containsKey(sid)) {
            endedIds.add(sid);
            while (endedIds.length > _maxEndedHistory) {
              final old = endedIds.removeAt(0);
              terminals.remove(old);
            }
          }
          saveSessionsLocally();
          break;

        case 'list':
          final list = msg['sessions'];
          if (list is! List) break;
          // 原子更新，不清空（保留本地 terminal）
          final serverIds = <String>{};
          for (final s in list) {
            if (s is! Map<String, dynamic>) continue;
            try {
              final info = SessionInfo.fromJson(s);
              serverIds.add(info.id);
              sessions[info.id] = info;
              terminalFor(info.id);
            } catch (_) {}
          }
          // 移除服务器已不存在的 session（但保留 terminal 供回看）
          final removedIds = sessions.keys
              .where((id) => !serverIds.contains(id))
              .toList();
          for (final id in removedIds) {
            sessions.remove(id);
            if (terminals.containsKey(id) && !endedIds.contains(id)) {
              endedIds.add(id);
            }
          }
          saveSessionsLocally();
          break;

        case 'error':
          debugPrint('Server: ${msg['msg']}');
          break;
      }

      notifyListeners();
    } catch (e) {
      debugPrint('Parse error: $e');
    }
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _reconnect?.cancel();
    _disconnectDebounce?.cancel();
    disconnect();
    super.dispose();
  }
}
