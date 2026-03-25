import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
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
  final _workDirCtrl = TextEditingController(text: '/Users');
  final _cmdCtrl = TextEditingController();
  bool _yolo = false;

  @override
  void dispose() {
    _promptCtrl.dispose();
    _workDirCtrl.dispose();
    _cmdCtrl.dispose();
    super.dispose();
  }

  bool get _isCustom => _agents[_agentIdx] == 'custom';

  void _start() {
    HapticFeedback.mediumImpact();

    context.read<RelayClient>().startSession(
          agent: _agents[_agentIdx],
          prompt: _promptCtrl.text.trim(),
          workDir: _workDirCtrl.text.trim(),
          yolo: _yolo,
          customCmd: _isCustom ? _cmdCtrl.text.trim() : null,
        );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖拽手柄
            Container(
              width: 36, height: 5,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(height: 20),

            const Text('New Session',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 24),

            // Agent
            CupertinoSlidingSegmentedControl<int>(
              groupValue: _agentIdx,
              children: {
                for (int i = 0; i < _agents.length; i++)
                  i: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text(_agents[i],
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                  ),
              },
              onValueChanged: (v) => setState(() => _agentIdx = v ?? 0),
            ),
            const SizedBox(height: 20),

            // Custom Command (仅 custom 模式)
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              child: _isCustom
                  ? Column(
                      children: [
                        _field(
                          ctrl: _cmdCtrl,
                          hint: 'Command or alias (e.g. my-claude)',
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
                onChanged: (v) {
                  HapticFeedback.selectionClick();
                  setState(() => _yolo = v);
                },
                title: Row(
                  children: [
                    const Text('YOLO Mode',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                    if (_yolo) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppTheme.red.withAlpha(20),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('ON',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.red)),
                      ),
                    ],
                  ],
                ),
                subtitle: const Text('Auto-approve all tool calls',
                    style: TextStyle(fontSize: 13)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
                onPressed: _start,
                child: Text(
                  _yolo ? 'Start YOLO' : 'Start Session',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
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
      prefix: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Icon(icon, size: 18, color: Colors.grey.shade500),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(14),
      ),
      style: TextStyle(color: isDark ? Colors.white : Colors.black, fontSize: 15),
    );
  }
}
