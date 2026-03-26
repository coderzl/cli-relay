import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';
import '../models/session.dart';

const _maxEndedHistory = 20;
const _sessionStorageKey = 'relay_sessions';

enum RelayConnectionState { disconnected, connecting, connected, reconnecting }

class RelayClient extends ChangeNotifier {
  WebSocketChannel? _ch;
  String _url = '';
  String _token = '';

  bool _wsConnected = false;
  RelayConnectionState _connectionState = RelayConnectionState.disconnected;
  Timer? _disconnectDebounce;
  Timer? _heartbeat;
  Timer? _reconnect;
  int _retries = 0;

  String _clientId = '';
  String _serverDefaultWorkDir = '';

  final Map<String, SessionInfo> sessions = {};
  final Map<String, Terminal> terminals = {};
  final Map<String, ApprovalRequest?> approvals = {};
  final List<String> endedIds = [];
  final Map<String, Completer<StartResult>> _pendingStarts = {};
  final Map<String, Timer> _pendingStartTimers = {};

  RelayConnectionState get connectionState => _connectionState;
  bool get connected => _connectionState == RelayConnectionState.connected;
  String get clientId => _clientId;
  String get serverDefaultWorkDir => _serverDefaultWorkDir;

  void Function(String msg)? onError;

  /// 用 SharedPreferences 初始化 clientId（同步，在 main 中调用）
  void initWithPrefs(SharedPreferences prefs) {
    final stored = prefs.getString('client_id');
    if (stored != null && stored.isNotEmpty) {
      _clientId = stored;
    } else {
      _clientId = _generateClientId();
      prefs.setString('client_id', _clientId);
    }
  }

  static String _generateClientId() {
    final r = Random();
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final rand = r.nextInt(0xFFFFFF).toRadixString(36).padLeft(4, '0');
    return '$ts$rand';
  }

  static String _generateReqId() {
    final r = Random();
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final rand = r.nextInt(0xFFFF).toRadixString(36).padLeft(3, '0');
    return '$ts$rand';
  }

  // ── 连接 ──────────────────────────────────────────────

  void connect(String url, String token) {
    _reconnect?.cancel();
    _disconnectDebounce?.cancel();
    disconnect();
    _url = url;
    _token = token;
    _retries = 0;
    _setConnectionState(RelayConnectionState.connecting);
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
    // 失败所有 pending 请求并取消超时 timer
    for (final t in _pendingStartTimers.values) { t.cancel(); }
    _pendingStartTimers.clear();
    for (final c in _pendingStarts.values) {
      if (!c.isCompleted) c.complete(StartResult.failure('Disconnected'));
    }
    _pendingStarts.clear();
    _setConnectionState(RelayConnectionState.disconnected);
  }

  void _setConnectionState(RelayConnectionState state) {
    if (_connectionState != state) {
      _connectionState = state;
      notifyListeners();
    }
  }

  void _onWsUp() {
    if (_wsConnected) return;
    _wsConnected = true;
    _retries = 0;
    _startHeartbeat();
    _send({'t': 'list'});
    _disconnectDebounce?.cancel();
    _setConnectionState(RelayConnectionState.connected);
  }

  void _onWsDrop() {
    if (!_wsConnected && _ch == null) return;
    _heartbeat?.cancel();
    _ch = null;
    _wsConnected = false;

    // 失败 pending 请求并取消超时 timer
    for (final t in _pendingStartTimers.values) { t.cancel(); }
    _pendingStartTimers.clear();
    for (final c in _pendingStarts.values) {
      if (!c.isCompleted) c.complete(StartResult.failure('Connection lost'));
    }
    _pendingStarts.clear();

    _disconnectDebounce?.cancel();
    _disconnectDebounce = Timer(const Duration(seconds: 5), () {
      if (!_wsConnected) {
        _setConnectionState(RelayConnectionState.reconnecting);
      }
    });

    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_url.isEmpty) return;
    final capped = _retries.clamp(0, 4);
    final delay = Duration(milliseconds: (500 * (1 << capped)).clamp(500, 8000));
    _retries++;
    _reconnect = Timer(delay, () {
      if (!_wsConnected && _url.isNotEmpty) {
        if (_connectionState == RelayConnectionState.disconnected) {
          _setConnectionState(RelayConnectionState.reconnecting);
        }
        _doConnect();
      }
    });
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      _send({'t': 'list'});
    });
  }

  // ── 发送 ──────────────────────────────────────────────

  void _send(Map<String, dynamic> msg) {
    if (_ch == null) return;
    try {
      _ch!.sink.add(jsonEncode(msg));
    } catch (e) {
      debugPrint('Send failed: $e');
    }
  }

  /// 启动 session，返回 Future 等待服务端确认
  Future<StartResult> startSession({
    required String agent,
    required String prompt,
    required String workDir,
    required bool yolo,
    String? customCmd,
  }) {
    if (!connected) {
      return Future.value(StartResult.failure('Not connected'));
    }

    final reqId = _generateReqId();
    final completer = Completer<StartResult>();
    _pendingStarts[reqId] = completer;

    _send({
      't': 'start',
      'reqId': reqId,
      'c': {
        'agent': agent,
        'prompt': prompt,
        'workDir': workDir,
        'yolo': yolo,
        if (customCmd != null && customCmd.isNotEmpty) 'customCmd': customCmd,
      },
      'source': 'app',
      'clientId': _clientId,
    });

    // 15s 超时（存储 timer 以便 disconnect 时取消）
    _pendingStartTimers[reqId] = Timer(const Duration(seconds: 15), () {
      _pendingStartTimers.remove(reqId);
      if (!completer.isCompleted) {
        _pendingStarts.remove(reqId);
        completer.complete(StartResult.failure('Request timed out'));
      }
    });

    return completer.future;
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

  // ── Session 持久化 ───────────────────────────────────

  Future<void> saveSessionsLocally() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = sessions.values
          .map((s) => jsonEncode({
                'id': s.id,
                'agent': s.agent,
                'workDir': s.workDir,
                'yolo': s.yolo,
                'startedAt': s.startedAt,
                'source': s.source,
              }))
          .toList();
      await prefs.setStringList(_sessionStorageKey, data);
    } catch (e) {
      debugPrint('Save sessions failed: $e');
    }
  }

  Future<void> loadSessionsLocally() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getStringList(_sessionStorageKey) ?? [];
      for (final entry in data) {
        try {
          final j = jsonDecode(entry) as Map<String, dynamic>;
          final id = j['id'] as String;
          if (!sessions.containsKey(id)) {
            sessions[id] = SessionInfo(
              id: id,
              agent: j['agent'] as String? ?? 'unknown',
              workDir: j['workDir'] as String? ?? '',
              yolo: j['yolo'] as bool? ?? false,
              status: 'running',
              startedAt: j['startedAt'] as int? ?? 0,
              source: j['source'] as String? ?? 'app',
            );
            terminalFor(id);
          }
        } catch (_) {}
      }
      notifyListeners();
    } catch (e) {
      debugPrint('Load sessions failed: $e');
    }
  }

  void _capEndedHistory() {
    while (endedIds.length > _maxEndedHistory) {
      final old = endedIds.removeAt(0);
      terminals.remove(old);
      approvals.remove(old);
    }
  }

  // ── 接收 ──────────────────────────────────────────────

  void _onRawMessage(dynamic raw) {
    _onWsUp();

    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      final t = msg['t'] as String?;
      if (t == null) return;

      switch (t) {
        case 'start_ack':
          final reqId = msg['reqId'] as String?;
          if (reqId == null) break;
          _pendingStartTimers.remove(reqId)?.cancel();
          final completer = _pendingStarts.remove(reqId);
          if (completer == null || completer.isCompleted) break;
          if (msg['result'] == 'ok') {
            final sessionData = msg['session'] as Map<String, dynamic>?;
            if (sessionData != null) {
              final info = SessionInfo.fromJson(sessionData);
              sessions[info.id] = info;
              terminalFor(info.id);
              completer.complete(StartResult.success(info));
              saveSessionsLocally();
            } else {
              completer.complete(StartResult.failure('Invalid server response'));
            }
          } else {
            completer.complete(
                StartResult.failure(msg['msg'] as String? ?? 'Unknown error'));
          }
          break;

        case 'started':
          // 更新 session 列表（所有客户端），不自动跳转
          final sessionData = msg['session'] as Map<String, dynamic>?;
          if (sessionData != null) {
            final info = SessionInfo.fromJson(sessionData);
            sessions[info.id] = info;
            terminalFor(info.id);
            saveSessionsLocally();
          }
          break;

        case 'data':
          final sid = msg['sid'] as String? ?? '';
          final d = msg['d'] as String?;
          if (sid.isEmpty || d == null) break;
          try {
            final bytes = base64Decode(d);
            terminalFor(sid).write(utf8.decode(bytes, allowMalformed: true));
          } catch (_) {}
          return; // 不触发 notifyListeners

        case 'approval':
          final sid = msg['sid'] as String? ?? '';
          if (sid.isEmpty) break;
          approvals[sid] = ApprovalRequest(
            sessionId: sid,
            tool: msg['tool'] as String? ?? 'tool',
            description: msg['desc'] as String? ?? '',
          );
          break;

        case 'ended':
          final sid = msg['sid'] as String? ?? '';
          if (sid.isEmpty) break;
          sessions.remove(sid);
          approvals.remove(sid);
          if (terminals.containsKey(sid) && !endedIds.contains(sid)) {
            endedIds.add(sid);
            _capEndedHistory();
          }
          saveSessionsLocally();
          break;

        case 'list':
          final list = msg['sessions'];
          if (list is! List) break;
          // 提取服务端配置
          final config = msg['config'] as Map<String, dynamic>?;
          if (config != null) {
            _serverDefaultWorkDir =
                config['defaultWorkDir'] as String? ?? '';
          }
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
          final removedIds = sessions.keys
              .where((id) => !serverIds.contains(id))
              .toList();
          for (final id in removedIds) {
            sessions.remove(id);
            approvals.remove(id);
            if (terminals.containsKey(id) && !endedIds.contains(id)) {
              endedIds.add(id);
            }
          }
          _capEndedHistory();
          saveSessionsLocally();
          break;

        case 'error':
          final errMsg = msg['msg'] as String? ?? 'Unknown error';
          debugPrint('Server error: $errMsg');
          onError?.call(errMsg);
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
    terminals.clear();
    super.dispose();
  }
}
