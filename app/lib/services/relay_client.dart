import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';
import '../models/session.dart';

const _maxEndedHistory = 20;

class RelayClient extends ChangeNotifier {
  WebSocketChannel? _ch;
  bool _connected = false;
  String _url = '';
  String _token = '';
  Timer? _heartbeat;
  Timer? _reconnect;
  int _retries = 0;

  final Map<String, SessionInfo> sessions = {};
  final Map<String, Terminal> terminals = {};
  final Map<String, ApprovalRequest?> approvals = {};
  final List<String> endedIds = [];

  bool get connected => _connected;

  VoidCallback? onApprovalReceived;
  void Function(String sid)? onSessionStarted; // 新 session 启动时回调

  // ── 连接 ──────────────────────────────────────────────

  void connect(String url, String token) {
    _reconnect?.cancel();
    disconnect();
    _url = url;
    _token = token;
    _retries = 0;
    _doConnect();
  }

  void _doConnect() {
    _reconnect?.cancel();
    try {
      _ch = WebSocketChannel.connect(Uri.parse('$_url?token=$_token'));
      _ch!.stream.listen(
        (raw) {
          if (!_connected) {
            _connected = true;
            _retries = 0;
            _startHeartbeat();
            notifyListeners();
          }
          _onMsg(raw);
        },
        onDone: _onDrop,
        onError: (_) => _onDrop(),
      );
      _send({'t': 'list'});
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void disconnect() {
    _heartbeat?.cancel();
    _ch?.sink.close();
    _ch = null;
    if (_connected) {
      _connected = false;
      notifyListeners();
    }
  }

  void _onDrop() {
    if (!_connected && _ch == null) return; // 防止重复触发
    _heartbeat?.cancel();
    _ch = null;
    _connected = false;
    notifyListeners();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_url.isEmpty) return;
    final capped = _retries.clamp(0, 5);
    final delay = Duration(seconds: (1 << capped).clamp(1, 30));
    _retries++;
    _reconnect = Timer(delay, () {
      if (!_connected && _url.isNotEmpty) _doConnect();
    });
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
      _send({'t': 'list'});
    });
  }

  // ── 发送 ──────────────────────────────────────────────

  void _send(Map<String, dynamic> msg) {
    if (_ch == null || !_connected) return;
    try {
      _ch!.sink.add(jsonEncode(msg));
    } catch (_) {
      _onDrop();
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

  void sendInput(String sid, String data) {
    _send({'t': 'input', 'sid': sid, 'd': data});
  }

  void resize(String sid, int cols, int rows) {
    _send({'t': 'resize', 'sid': sid, 'cols': cols, 'rows': rows});
  }

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

  void stopSession(String sid) {
    _send({'t': 'stop', 'sid': sid});
  }

  void refresh() => _send({'t': 'list'});

  void clearEnded(String sid) {
    endedIds.remove(sid);
    terminals.remove(sid);
    approvals.remove(sid);
    notifyListeners();
  }

  Terminal terminalFor(String sid) {
    return terminals.putIfAbsent(sid, () => Terminal(maxLines: 10000));
  }

  // ── 接收 ──────────────────────────────────────────────

  void _onMsg(dynamic raw) {
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
          break;

        case 'data':
          final sid = msg['sid'] as String? ?? '';
          final d = msg['d'] as String?;
          if (sid.isEmpty || d == null) break;
          try {
            final bytes = base64Decode(d);
            // 正确 UTF-8 解码，支持中文、emoji 等
            terminalFor(sid).write(utf8.decode(bytes, allowMalformed: true));
          } catch (_) {}
          break;

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
            // 限制历史数量，防止内存泄漏
            while (endedIds.length > _maxEndedHistory) {
              final old = endedIds.removeAt(0);
              terminals.remove(old);
              approvals.remove(old);
            }
          }
          break;

        case 'list':
          final list = msg['sessions'];
          if (list is! List) break;
          // 原子更新，避免 UI 闪烁
          final updated = <String, SessionInfo>{};
          for (final s in list) {
            if (s is! Map<String, dynamic>) continue;
            try {
              final info = SessionInfo.fromJson(s);
              updated[info.id] = info;
              terminalFor(info.id);
            } catch (_) {}
          }
          sessions.clear();
          sessions.addAll(updated);
          break;

        case 'error':
          debugPrint('Server error: ${msg['msg']}');
          break;
      }

      notifyListeners();
    } catch (e) {
      debugPrint('Failed to parse message: $e');
    }
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _reconnect?.cancel();
    disconnect();
    super.dispose();
  }
}
