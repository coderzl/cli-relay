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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _autoConnect();

    // 新 session 创建时自动跳转到对话页
    context.read<RelayClient>().onSessionStarted = (sid) {
      if (mounted) {
        Navigator.push(
          context,
          CupertinoPageRoute(builder: (_) => SessionScreen(sessionId: sid)),
        );
      }
    };
  }

  @override
  void dispose() {
    context.read<RelayClient>().onSessionStarted = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // App 从后台恢复 → 自动重连 + 刷新
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final relay = context.read<RelayClient>();
      if (!relay.connected) {
        _autoConnect();
      } else {
        relay.refresh();
      }
    }
  }

  Future<void> _autoConnect() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('server_url');
    final token = prefs.getString('auth_token');
    if (url != null && token != null && url.isNotEmpty && mounted) {
      context.read<RelayClient>().connect(url, token);
    }
  }

  @override
  Widget build(BuildContext context) {
    final relay = context.watch<RelayClient>();
    final theme = Theme.of(context);
    final sessions = relay.sessions.values.toList();
    final ended = relay.endedIds;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: relay.connected
                    ? const Color(0xFF34C759)
                    : const Color(0xFFFF3B30),
                boxShadow: [
                  BoxShadow(
                    color: (relay.connected
                            ? const Color(0xFF34C759)
                            : const Color(0xFFFF3B30))
                        .withAlpha(100),
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
              final modes = [ThemeMode.system, ThemeMode.light, ThemeMode.dark];
              final next = modes[(modes.indexOf(svc.themeMode) + 1) % 3];
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
          ? _buildEmpty(relay.connected, theme)
          : RefreshIndicator(
              onRefresh: () async => relay.refresh(),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (sessions.isNotEmpty) ...[
                    _sectionHeader('ACTIVE · ${sessions.length}', theme),
                    ...sessions.map((s) => SessionCard(
                          session: s,
                          hasApproval: relay.approvals[s.id] != null,
                          onTap: () => Navigator.push(
                            context,
                            CupertinoPageRoute(
                              builder: (_) => SessionScreen(sessionId: s.id),
                            ),
                          ),
                        )),
                  ],
                  if (ended.isNotEmpty) ...[
                    _sectionHeader('HISTORY', theme),
                    ...ended.map((id) => _historyTile(id, relay, theme)),
                  ],
                  const SizedBox(height: 100),
                ],
              ),
            ),
      floatingActionButton: relay.connected
          ? FloatingActionButton(
              onPressed: () {
                HapticFeedback.mediumImpact();
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => const NewSessionScreen(),
                );
              },
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: Colors.white,
              elevation: 3,
              child: const Icon(CupertinoIcons.add, size: 26),
            )
          : null,
    );
  }

  Widget _buildEmpty(bool connected, ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppLogo(size: 72),
          const SizedBox(height: 24),
          Text(
            connected ? 'No active sessions' : 'Not connected',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            connected ? 'Tap + to start' : 'Go to Settings to connect',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade400),
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

  Widget _historyTile(String id, RelayClient relay, ThemeData theme) {
    return Dismissible(
      key: ValueKey(id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => relay.clearEnded(id),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFFF3B30),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(CupertinoIcons.delete, color: Colors.white),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Material(
          color: theme.cardTheme.color,
          borderRadius: BorderRadius.circular(14),
          child: ListTile(
            onTap: () => Navigator.push(context,
                CupertinoPageRoute(builder: (_) => SessionScreen(sessionId: id))),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            leading: Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: Colors.grey.withAlpha(20),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(CupertinoIcons.doc_text, size: 20, color: Colors.grey),
            ),
            title: Text(id, style: const TextStyle(fontFamily: 'monospace', fontSize: 15)),
            subtitle: const Text('Ended — tap to review',
                style: TextStyle(fontSize: 13, color: Colors.grey)),
            trailing: Icon(CupertinoIcons.chevron_forward,
                size: 14, color: Colors.grey.shade400),
          ),
        ),
      ),
    );
  }
}
