import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import '../services/relay_client.dart';
import '../widgets/approval_sheet.dart';
import '../theme/app_theme.dart';

class SessionScreen extends StatefulWidget {
  final String sessionId;
  const SessionScreen({super.key, required this.sessionId});

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final _inputCtrl = TextEditingController();
  final _inputFocus = FocusNode();
  late Terminal _terminal;
  bool _approvalSheetShown = false;
  // [FC9+F4] 用单调计数器去重
  int? _lastApprovalSeq;

  @override
  void initState() {
    super.initState();
    _terminal = context.read<RelayClient>().terminalFor(widget.sessionId);
    // 进入页面后自动聚焦输入框
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _sendInput() {
    final text = _inputCtrl.text;
    if (text.isEmpty) return;
    context.read<RelayClient>().sendInput(widget.sessionId, '$text\r'); // PTY: CR not LF
    _inputCtrl.clear();
  }

  void _showApproval(RelayClient relay) {
    if (!mounted) return; // [FH10]
    final approval = relay.approvals[widget.sessionId];
    if (approval == null || _approvalSheetShown) return;

    _approvalSheetShown = true;
    _lastApprovalSeq = approval.seq;
    HapticFeedback.heavyImpact();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => ApprovalSheet(
        approval: approval,
        onApprove: () => relay.approve(widget.sessionId),
        onDeny: () => relay.deny(widget.sessionId),
      ),
    ).whenComplete(() {
      _approvalSheetShown = false;
    });
  }

  void _copyAllOutput() {
    // xterm 4.0: 通过 buffer 获取文本
    try {
      final buffer = _terminal.buffer;
      final lines = <String>[];
      for (int i = 0; i < buffer.lines.length; i++) {
        lines.add(buffer.lines[i].toString());
      }
      Clipboard.setData(ClipboardData(text: lines.join('\n')));
    } catch (_) {
      Clipboard.setData(const ClipboardData(text: '[Copy failed]'));
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Terminal output copied'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final relay = context.watch<RelayClient>();
    final session = relay.sessions[widget.sessionId];
    final approval = relay.approvals[widget.sessionId];
    final isAlive = session != null;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // [FC9] 有新审批时自动弹出（用时间戳去重，同一 tool 可多次审批）
    if (approval != null && !_approvalSheetShown && approval.seq != _lastApprovalSeq) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showApproval(relay);
      });
    }
    if (approval == null) {
      _lastApprovalSeq = null;
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(CupertinoIcons.back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          children: [
            Text(session?.agent ?? widget.sessionId,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6, height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: !relay.connected
                        ? AppTheme.orange // 断线 = 橙色（非红色，减少焦虑）
                        : isAlive ? AppTheme.green : Colors.grey,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  !relay.connected
                      ? 'Reconnecting...'
                      : isAlive ? widget.sessionId : 'Ended',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(CupertinoIcons.doc_on_clipboard, size: 20),
            tooltip: 'Copy all',
            onPressed: _copyAllOutput,
          ),
          if (approval != null)
            IconButton(
              icon: const Icon(CupertinoIcons.shield_lefthalf_fill,
                  size: 22, color: Color(0xFFFF9500)),
              onPressed: () => _showApproval(relay),
            ),
          if (isAlive)
            IconButton(
              icon: const Icon(CupertinoIcons.stop_circle,
                  size: 22, color: Color(0xFFFF3B30)),
              onPressed: () {
                HapticFeedback.mediumImpact();
                relay.stopSession(widget.sessionId);
              },
            ),
        ],
      ),
      body: Column(
        children: [
          // ── 终端视图 (真终端渲染) ─────────────────────
          Expanded(
            child: AbsorbPointer(
              // 禁止终端区域的点击/触摸，输入只通过底部输入框
              child: Container(
                color: isDark ? Colors.black : const Color(0xFF1A1A2E),
                padding: EdgeInsets.only(
                  bottom: !isAlive ? MediaQuery.of(context).viewPadding.bottom : 0,
                ),
                child: TerminalView(
                  _terminal,
                  textStyle: const TerminalStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                  padding: const EdgeInsets.all(8),
                  autofocus: false,
                  onKeyEvent: (node, key) => KeyEventResult.ignored,
                ),
              ),
            ),
          ),

          // ── 底部操作栏 ────────────────────────────────
          if (isAlive) _buildBottomBar(theme, relay, isDark),
        ],
      ),
    );
  }

  Widget _buildBottomBar(ThemeData theme, RelayClient relay, bool isDark) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          12, 8, 12, MediaQuery.of(context).viewPadding.bottom + 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        border: Border(top: BorderSide(color: theme.dividerTheme.color ?? theme.dividerColor)),
      ),
      child: Row(
        children: [
          _QuickBtn(
            label: 'y',
            color: AppTheme.green,
            onTap: () {
              HapticFeedback.lightImpact();
              relay.sendInput(widget.sessionId, 'y\r');
            },
          ),
          const SizedBox(width: 6),
          _QuickBtn(
            label: 'n',
            color: AppTheme.red,
            onTap: () {
              HapticFeedback.lightImpact();
              relay.sendInput(widget.sessionId, 'n\r');
            },
          ),
          const SizedBox(width: 10),
          Expanded(
            child: CupertinoTextField(
              controller: _inputCtrl,
              focusNode: _inputFocus,
              placeholder: 'Send input...',
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF2C2C2E) : const Color(0xFFF2F2F7),
                borderRadius: BorderRadius.circular(20),
              ),
              style: TextStyle(
                color: isDark ? Colors.white : Colors.black,
                fontSize: 15,
              ),
              onSubmitted: (_) => _sendInput(),
              textInputAction: TextInputAction.send,
            ),
          ),
          const SizedBox(width: 8),
          CupertinoButton(
            padding: EdgeInsets.zero,
            minSize: 36,
            onPressed: _sendInput,
            child: Icon(CupertinoIcons.arrow_up_circle_fill,
                size: 34, color: theme.colorScheme.primary),
          ),
        ],
      ),
    );
  }
}

class _QuickBtn extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _QuickBtn({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 36,
        decoration: BoxDecoration(
          color: color.withAlpha(20),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withAlpha(60)),
        ),
        child: Center(
          child: Text(label,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, color: color)),
        ),
      ),
    );
  }
}
