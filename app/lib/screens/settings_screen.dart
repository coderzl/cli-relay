import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/relay_client.dart';
import '../services/theme_service.dart';
import '../widgets/app_logo.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    _urlCtrl.text = p.getString('server_url') ?? '';
    _tokenCtrl.text = p.getString('auth_token') ?? '';
  }

  Future<void> _save() async {
    final url = _urlCtrl.text.trim();
    final token = _tokenCtrl.text.trim();
    if (url.isEmpty || token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('URL and token are required'),
            behavior: SnackBarBehavior.floating),
      );
      return;
    }

    final p = await SharedPreferences.getInstance();
    await p.setString('server_url', url);
    await p.setString('auth_token', token);
    if (mounted) {
      context.read<RelayClient>().connect(url, token);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Saved & connecting...'),
            behavior: SnackBarBehavior.floating),
      );
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final relay = context.watch<RelayClient>();
    final themeSvc = context.watch<ThemeService>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // 连接状态
    final connState = relay.connectionState;
    final connIcon = switch (connState) {
      RelayConnectionState.connected =>
        CupertinoIcons.checkmark_circle_fill,
      RelayConnectionState.connecting ||
      RelayConnectionState.reconnecting =>
        CupertinoIcons.arrow_2_circlepath,
      RelayConnectionState.disconnected =>
        CupertinoIcons.xmark_circle_fill,
    };
    final connColor = switch (connState) {
      RelayConnectionState.connected => AppTheme.green,
      RelayConnectionState.connecting ||
      RelayConnectionState.reconnecting =>
        AppTheme.orange,
      RelayConnectionState.disconnected => AppTheme.red,
    };
    final connLabel = switch (connState) {
      RelayConnectionState.connected => 'Connected',
      RelayConnectionState.connecting => 'Connecting...',
      RelayConnectionState.reconnecting => 'Reconnecting...',
      RelayConnectionState.disconnected => 'Disconnected',
    };
    final connSub = switch (connState) {
      RelayConnectionState.connected => 'WebSocket active',
      RelayConnectionState.connecting ||
      RelayConnectionState.reconnecting =>
        'Please wait...',
      RelayConnectionState.disconnected => 'Configure below',
    };

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(CupertinoIcons.back),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          const SizedBox(height: 24),

          // Logo + 版本
          Center(
            child: Column(
              children: [
                const AppLogo(size: 64),
                const SizedBox(height: 12),
                Text('CLI Relay',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface)),
                Text('v1.1.0',
                    style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade500)),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // ── Connection
          _GroupCard(
            children: [
              ListTile(
                leading: Icon(connIcon, color: connColor),
                title: Text(connLabel),
                subtitle: Text(connSub,
                    style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade500)),
              ),
            ],
          ),
          const SizedBox(height: 20),

          _section('SERVER'),
          _GroupCard(
            children: [
              _inputTile(
                ctrl: _urlCtrl,
                hint: 'wss://your-tunnel-url.trycloudflare.com',
                icon: CupertinoIcons.link,
                isDark: isDark,
                theme: theme,
              ),
              Divider(
                  height: 0.5,
                  indent: 52,
                  color: theme.dividerTheme.color),
              _inputTile(
                ctrl: _tokenCtrl,
                hint: 'Auth Token',
                icon: CupertinoIcons.lock,
                isDark: isDark,
                theme: theme,
                obscure: true,
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: CupertinoButton.filled(
                    padding: const EdgeInsets.symmetric(
                        vertical: 12),
                    borderRadius: BorderRadius.circular(10),
                    onPressed: _save,
                    child: const Text('Save & Connect',
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ── Appearance
          _section('APPEARANCE'),
          _GroupCard(
            children: [
              ListTile(
                leading: Icon(themeSvc.icon,
                    color: theme.colorScheme.primary),
                title: const Text('Theme'),
                trailing:
                    CupertinoSlidingSegmentedControl<ThemeMode>(
                  groupValue: themeSvc.themeMode,
                  children: const {
                    ThemeMode.system: Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 4),
                      child: Text('Auto',
                          style: TextStyle(fontSize: 13)),
                    ),
                    ThemeMode.light: Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 4),
                      child: Text('Light',
                          style: TextStyle(fontSize: 13)),
                    ),
                    ThemeMode.dark: Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 4),
                      child: Text('Dark',
                          style: TextStyle(fontSize: 13)),
                    ),
                  },
                  onValueChanged: (v) {
                    if (v != null) themeSvc.setMode(v);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          _section('INFO'),
          _GroupCard(
            children: [
              _infoTile(CupertinoIcons.globe,
                  'Use Cloudflare Tunnel for remote access'),
              Divider(
                  height: 0.5,
                  indent: 52,
                  color: theme.dividerTheme.color),
              _infoTile(CupertinoIcons.arrow_2_circlepath,
                  'Auto-reconnects on disconnect'),
              Divider(
                  height: 0.5,
                  indent: 52,
                  color: theme.dividerTheme.color),
              _infoTile(Icons.terminal,
                  'Supports zsh alias & custom commands'),
            ],
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(left: 16, bottom: 8),
        child: Text(t,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade500,
                letterSpacing: 0.5)),
      );

  Widget _inputTile({
    required TextEditingController ctrl,
    required String hint,
    required IconData icon,
    required bool isDark,
    required ThemeData theme,
    bool obscure = false,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: CupertinoTextField(
        controller: ctrl,
        placeholder: hint,
        obscureText: obscure,
        prefix: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Icon(icon,
              size: 18, color: Colors.grey.shade500),
        ),
        padding: const EdgeInsets.symmetric(
            horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(10),
        ),
        style: TextStyle(
            color: isDark ? Colors.white : Colors.black),
      ),
    );
  }

  Widget _infoTile(IconData icon, String text) => ListTile(
        dense: true,
        leading:
            Icon(icon, size: 18, color: Colors.grey.shade500),
        title: Text(text,
            style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade600)),
      );
}

class _GroupCard extends StatelessWidget {
  final List<Widget> children;
  const _GroupCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
          mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}
