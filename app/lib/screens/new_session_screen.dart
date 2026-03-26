import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/relay_client.dart';
import '../theme/app_theme.dart';

class NewSessionScreen extends StatefulWidget {
  const NewSessionScreen({super.key});

  @override
  State<NewSessionScreen> createState() => _NewSessionScreenState();
}

class _NewSessionScreenState extends State<NewSessionScreen> {
  final _agents = ['claude', 'codex', 'qoder', 'custom'];
  int _agentIdx = 0;
  final _promptCtrl = TextEditingController();
  final _workDirCtrl = TextEditingController();
  final _cmdCtrl = TextEditingController();
  bool _yolo = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadLastUsed();
  }

  Future<void> _loadLastUsed() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final lastWorkDir = prefs.getString('last_workdir');
    final lastAgent = prefs.getString('last_agent');
    setState(() {
      if (lastWorkDir != null && lastWorkDir.isNotEmpty) {
        _workDirCtrl.text = lastWorkDir;
      } else {
        final relay = context.read<RelayClient>();
        if (relay.serverDefaultWorkDir.isNotEmpty) {
          _workDirCtrl.text = relay.serverDefaultWorkDir;
        }
      }
      if (lastAgent != null) {
        final idx = _agents.indexOf(lastAgent);
        if (idx >= 0) _agentIdx = idx;
      }
    });
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    _workDirCtrl.dispose();
    _cmdCtrl.dispose();
    super.dispose();
  }

  bool get _isCustom => _agents[_agentIdx] == 'custom';

  Future<void> _start() async {
    final workDir = _workDirCtrl.text.trim();
    if (workDir.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Working directory is required'),
            behavior: SnackBarBehavior.floating),
      );
      return;
    }
    if (_isCustom && _cmdCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Custom command is required'),
            behavior: SnackBarBehavior.floating),
      );
      return;
    }

    final relay = context.read<RelayClient>();
    if (!relay.connected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Not connected to server'),
            behavior: SnackBarBehavior.floating),
      );
      return;
    }

    setState(() => _loading = true);
    HapticFeedback.mediumImpact();

    try {
      final result = await relay.startSession(
        agent: _agents[_agentIdx],
        prompt: _promptCtrl.text.trim(),
        workDir: workDir,
        yolo: _yolo,
        customCmd: _isCustom ? _cmdCtrl.text.trim() : null,
      );

      if (!mounted) return;

      if (result.ok) {
        // 记住成功的配置
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_workdir', workDir);
        await prefs.setString('last_agent', _agents[_agentIdx]);
        if (mounted) Navigator.pop(context, result.sid);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(result.error ?? 'Failed to start session'),
              behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Error: $e'),
            behavior: SnackBarBehavior.floating),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖拽手柄
            Container(
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(height: 20),

            const Text('New Session',
                style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 24),

            // Agent
            CupertinoSlidingSegmentedControl<int>(
              groupValue: _agentIdx,
              children: {
                for (int i = 0; i < _agents.length; i++)
                  i: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    child: Text(_agents[i],
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500)),
                  ),
              },
              onValueChanged: (v) {
                if (!_loading) setState(() => _agentIdx = v ?? 0);
              },
            ),
            const SizedBox(height: 20),

            // Custom Command
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              child: _isCustom
                  ? Column(
                      children: [
                        _field(
                          ctrl: _cmdCtrl,
                          hint:
                              'Command or alias (e.g. my-claude)',
                          icon: CupertinoIcons.command,
                          isDark: isDark,
                          theme: theme,
                        ),
                        const SizedBox(height: 12),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),

            // Prompt
            _field(
              ctrl: _promptCtrl,
              hint: 'Prompt (optional, leave empty for interactive)',
              icon: CupertinoIcons.text_cursor,
              isDark: isDark,
              theme: theme,
              maxLines: 4,
              autofocus: true,
            ),
            const SizedBox(height: 12),

            // Work Dir
            _field(
              ctrl: _workDirCtrl,
              hint: 'Working directory',
              icon: CupertinoIcons.folder,
              isDark: isDark,
              theme: theme,
            ),
            const SizedBox(height: 12),

            // YOLO
            Container(
              decoration: BoxDecoration(
                color: theme.cardTheme.color,
                borderRadius: BorderRadius.circular(14),
              ),
              child: SwitchListTile.adaptive(
                value: _yolo,
                onChanged: _loading
                    ? null
                    : (v) {
                        HapticFeedback.selectionClick();
                        setState(() => _yolo = v);
                      },
                title: Row(
                  children: [
                    const Text('YOLO Mode',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500)),
                    if (_yolo) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppTheme.red.withAlpha(20),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('ON',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.red)),
                      ),
                    ],
                  ],
                ),
                subtitle: const Text(
                    'Auto-approve all tool calls',
                    style: TextStyle(fontSize: 13)),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 4),
                activeColor: AppTheme.red,
              ),
            ),
            const SizedBox(height: 24),

            // Start
            SizedBox(
              width: double.infinity,
              height: 52,
              child: CupertinoButton.filled(
                borderRadius: BorderRadius.circular(14),
                onPressed: _loading ? null : _start,
                child: _loading
                    ? const CupertinoActivityIndicator(
                        color: Colors.white)
                    : Text(
                        _yolo ? 'Start YOLO' : 'Start Session',
                        style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController ctrl,
    required String hint,
    required IconData icon,
    required bool isDark,
    required ThemeData theme,
    int maxLines = 1,
    bool autofocus = false,
  }) {
    return CupertinoTextField(
      controller: ctrl,
      placeholder: hint,
      maxLines: maxLines,
      autofocus: autofocus,
      enabled: !_loading,
      prefix: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Icon(icon, size: 18, color: Colors.grey.shade500),
      ),
      padding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(14),
      ),
      style: TextStyle(
          color: isDark ? Colors.white : Colors.black, fontSize: 15),
    );
  }
}
