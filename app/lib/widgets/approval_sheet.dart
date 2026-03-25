import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/session.dart';
import '../theme/app_theme.dart';

class ApprovalSheet extends StatelessWidget {
  final ApprovalRequest approval;
  final VoidCallback onApprove;
  final VoidCallback onDeny;

  const ApprovalSheet({
    super.key,
    required this.approval,
    required this.onApprove,
    required this.onDeny,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(
          20, 12, 20, MediaQuery.of(context).viewPadding.bottom + 20),
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

          // 标题
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(CupertinoIcons.shield_lefthalf_fill,
                  color: AppTheme.orange, size: 24),
              const SizedBox(width: 10),
              const Text('Permission Required',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 16),

          // 描述 (可复制)
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 250),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.cardTheme.color,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.orange.withAlpha(40)),
            ),
            child: SingleChildScrollView(
              child: GestureDetector(
                onLongPress: () {
                  Clipboard.setData(ClipboardData(text: approval.description));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied'), duration: Duration(milliseconds: 600)),
                  );
                },
                child: SelectableText(
                  approval.description,
                  style: const TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 按钮
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: CupertinoButton(
                    color: AppTheme.red,
                    borderRadius: BorderRadius.circular(14),
                    onPressed: () {
                      HapticFeedback.mediumImpact();
                      onDeny();
                      Navigator.pop(context);
                    },
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(CupertinoIcons.xmark, size: 18, color: Colors.white),
                        SizedBox(width: 8),
                        Text('Deny', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: CupertinoButton(
                    color: AppTheme.green,
                    borderRadius: BorderRadius.circular(14),
                    onPressed: () {
                      HapticFeedback.mediumImpact();
                      onApprove();
                      Navigator.pop(context);
                    },
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(CupertinoIcons.checkmark_alt, size: 18, color: Colors.white),
                        SizedBox(width: 8),
                        Text('Approve', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
