class SessionInfo {
  final String id;
  final String agent;
  final String workDir;
  final bool yolo;
  final String status;
  final int startedAt;
  final String source;
  final String? initiatorClientId;
  final int? exitCode;

  SessionInfo({
    required this.id,
    required this.agent,
    required this.workDir,
    required this.yolo,
    required this.status,
    required this.startedAt,
    this.source = 'app',
    this.initiatorClientId,
    this.exitCode,
  });

  factory SessionInfo.fromJson(Map<String, dynamic> j) => SessionInfo(
        id: j['id'] as String,
        agent: j['agent'] as String,
        workDir: j['workDir'] as String,
        yolo: j['yolo'] as bool? ?? false,
        status: j['status'] as String? ?? 'running',
        startedAt: j['startedAt'] as int? ?? 0,
        source: j['source'] as String? ?? 'app',
        initiatorClientId: j['initiatorClientId'] as String?,
        exitCode: j['exitCode'] as int?,
      );

  String get duration {
    final secs = (DateTime.now().millisecondsSinceEpoch - startedAt) ~/ 1000;
    if (secs < 60) return '${secs}s';
    if (secs < 3600) return '${secs ~/ 60}m ${secs % 60}s';
    return '${secs ~/ 3600}h ${(secs % 3600) ~/ 60}m';
  }
}

class ApprovalRequest {
  static int _counter = 0;
  final int seq;
  final String sessionId;
  final String tool;
  final String description;

  ApprovalRequest({
    required this.sessionId,
    required this.tool,
    required this.description,
  }) : seq = ++_counter;
}

class StartResult {
  final bool ok;
  final String? sid;
  final SessionInfo? session;
  final String? error;

  StartResult.success(SessionInfo this.session)
      : ok = true,
        sid = session.id,
        error = null;

  StartResult.failure(this.error)
      : ok = false,
        sid = null,
        session = null;
}
