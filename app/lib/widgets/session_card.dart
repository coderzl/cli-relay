import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/session.dart';
import '../theme/app_theme.dart';

class SessionCard extends StatelessWidget {
  final SessionInfo session;
  final bool hasApproval;
  final VoidCallback onTap;

  const SessionCard({
    super.key,
    required this.session,
    this.hasApproval = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // ── 图标 ──────────────────────────────
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: hasApproval
                        ? AppTheme.orange.withAlpha(25)
                        : theme.colorScheme.primary.withAlpha(20),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    hasApproval
                        ? CupertinoIcons.exclamationmark_shield_fill
                        : CupertinoIcons.terminal_fill,
                    size: 22,
                    color: hasApproval ? AppTheme.orange : theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 14),

                // ── 信息 ──────────────────────────────
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          Text(session.agent,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                          _Tag(session.id, theme.colorScheme.primary.withAlpha(20),
                              theme.colorScheme.primary),
                          if (session.yolo)
                            _Tag('YOLO', AppTheme.red.withAlpha(20), AppTheme.red),
                          if (hasApproval)
                            _Tag('APPROVE', AppTheme.orange.withAlpha(20), AppTheme.orange),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        session.workDir,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.grey.shade500 : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),

                // ── 时长 + 箭头 ──────────────────────
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(session.duration,
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                    const SizedBox(height: 4),
                    Icon(CupertinoIcons.chevron_forward,
                        size: 14, color: Colors.grey.shade400),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  const _Tag(this.text, this.bg, this.fg);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(5)),
      child: Text(text,
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: fg, fontFamily: 'monospace')),
    );
  }
}
