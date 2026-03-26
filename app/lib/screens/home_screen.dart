import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/relay_client.dart';
import '../services/theme_service.dart';
import '../widgets/session_card.dart';
import '../widgets/app_logo.dart';
import 'session_screen.dart';
import 'new_session_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final RelayClient _relay;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _relay = context.read<RelayClient>();

    _relay.loadSessionsLocally().catchError((_) {});

    _relay.onError = (msg) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Error: $msg'),
              behavior: SnackBarBehavior.floating),
        );
      }
    };

    _autoConnect();
  }

  @override
  void dispose() {
    _relay.onError = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_relay.connected) {
        _autoConnect();
      } else {
        _relay.refresh();
      }
    }
  }

  Future<void> _autoConnect() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('server_url');
    final token = prefs.getString('auth_token');
    if (url != null && token != null && url.isNotEmpty && mounted) {
      _relay.connect(url, token);
    }
  }

  void _openNewSession() {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const NewSessionScreen(),
    ).then((sid) {
      if (sid != null && sid is String && mounted) {
        Navigator.push(
          context,
          CupertinoPageRoute(
              builder: (_) => SessionScreen(sessionId: sid)),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final relay = context.watch<RelayClient>();
    final theme = Theme.of(context);
    final sessions = relay.sessions.values.toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final ended = relay.endedIds;

    // 连接状态颜色
    final connState = relay.connectionState;
    final dotColor = switch (connState) {
      RelayConnectionState.connected => const Color(0xFF34C759),
      RelayConnectionState.connecting ||
      RelayConnectionState.reconnecting =>
        const Color(0xFFFF9500),
      RelayConnectionState.disconnected => Colors.grey,
    };

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dotColor,
                boxShadow: [
                  BoxShadow(
                    color: dotColor.withAlpha(100),
                    blurRadius: 6,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            const Text('CLI Relay'),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(context.watch<ThemeService>().icon, size: 21),
            onPressed: () {
              HapticFeedback.lightImpact();
              final svc = context.read<ThemeService>();
              final modes = [
                ThemeMode.system,
                ThemeMode.light,
                ThemeMode.dark
              ];
              final next =
                  modes[(modes.indexOf(svc.themeMode) + 1) % 3];
              svc.setMode(next);
            },
          ),
          IconButton(
            icon: const Icon(CupertinoIcons.gear, size: 21),
            onPressed: () => Navigator.push(context,
                CupertinoPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: sessions.isEmpty && ended.isEmpty
          ? _buildEmpty(relay, theme)
          : RefreshIndicator(
              onRefresh: () async => relay.refresh(),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (sessions.isNotEmpty) ...[
                    _sectionHeader(
                        'ACTIVE \u00b7 ${sessions.length}', theme),
                    ...sessions.map((s) => SessionCard(
                          session: s,
                          hasApproval: relay.approvals[s.id] != null,
                          onTap: () => Navigator.push(
                            context,
                            CupertinoPageRoute(
                              builder: (_) =>
                                  SessionScreen(sessionId: s.id),
                            ),
                          ),
                        )),
                  ],
                  if (ended.isNotEmpty) ...[
                    _sectionHeader('HISTORY', theme),
                    ...ended.map(
                        (id) => _historyTile(id, relay, theme)),
                  ],
                  const SizedBox(height: 100),
                ],
              ),
            ),
      floatingActionButton: relay.connected
          ? FloatingActionButton(
              onPressed: _openNewSession,
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: Colors.white,
              elevation: 3,
              child: const Icon(CupertinoIcons.add, size: 26),
            )
          : null,
    );
  }

  Widget _buildEmpty(RelayClient relay, ThemeData theme) {
    final connState = relay.connectionState;
    final label = switch (connState) {
      RelayConnectionState.connected => 'No active sessions',
      RelayConnectionState.connecting => 'Connecting...',
      RelayConnectionState.reconnecting => 'Reconnecting...',
      RelayConnectionState.disconnected => 'Not connected',
    };
    final sub = switch (connState) {
      RelayConnectionState.connected => 'Tap + to start',
      RelayConnectionState.connecting ||
      RelayConnectionState.reconnecting =>
        'Please wait...',
      RelayConnectionState.disconnected =>
        'Go to Settings to connect',
    };

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppLogo(size: 72),
          const SizedBox(height: 24),
          Text(
            label,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            sub,
            style:
                TextStyle(fontSize: 14, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String text, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 20, 16, 8),
      child: Text(text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade500,
            letterSpacing: 0.8,
          )),
    );
  }

  Widget _historyTile(
      String id, RelayClient relay, ThemeData theme) {
    return Dismissible(
      key: ValueKey(id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => relay.clearEnded(id),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        margin:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFFF3B30),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(CupertinoIcons.delete,
            color: Colors.white),
      ),
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Material(
          color: theme.cardTheme.color,
          borderRadius: BorderRadius.circular(14),
          child: ListTile(
            onTap: () => Navigator.push(
                context,
                CupertinoPageRoute(
                    builder: (_) =>
                        SessionScreen(sessionId: id))),
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 6),
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.grey.withAlpha(20),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(CupertinoIcons.doc_text,
                  size: 20, color: Colors.grey),
            ),
            title: Text(id,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 15)),
            subtitle: const Text('Ended \u2014 tap to review',
                style:
                    TextStyle(fontSize: 13, color: Colors.grey)),
            trailing: Icon(CupertinoIcons.chevron_forward,
                size: 14, color: Colors.grey.shade400),
          ),
        ),
      ),
    );
  }
}
