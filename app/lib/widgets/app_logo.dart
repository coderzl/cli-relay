import 'dart:math';
import 'package:flutter/material.dart';

class AppLogo extends StatelessWidget {
  final double size;
  const AppLogo({super.key, this.size = 80});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _LogoPainter()),
    );
  }
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final r = s * 0.22;

    // ── Background: 圆角矩形 + 渐变 ────────────────────
    final bg = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, s, s), Radius.circular(r));
    canvas.drawRRect(
      bg,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF6C5CE7), Color(0xFF0984E3)],
        ).createShader(Rect.fromLTWH(0, 0, s, s)),
    );

    // ── 微光效果 ────────────────────────────────────────
    canvas.drawCircle(
      Offset(s * 0.3, s * 0.25),
      s * 0.35,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.white.withAlpha(30), Colors.white.withAlpha(0)],
        ).createShader(Rect.fromCircle(center: Offset(s * 0.3, s * 0.25), radius: s * 0.35)),
    );

    // ── ">" 提示符 ──────────────────────────────────────
    final promptP = Paint()
      ..color = Colors.white
      ..strokeWidth = s * 0.065
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    canvas.drawPath(
      Path()
        ..moveTo(s * 0.22, s * 0.32)
        ..lineTo(s * 0.44, s * 0.50)
        ..lineTo(s * 0.22, s * 0.68),
      promptP,
    );

    // ── 光标下划线 (闪烁感: 渐变透明) ────────────────────
    canvas.drawLine(
      Offset(s * 0.50, s * 0.67),
      Offset(s * 0.72, s * 0.67),
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white.withAlpha(240), Colors.white.withAlpha(100)],
        ).createShader(Rect.fromPoints(Offset(s * 0.50, 0), Offset(s * 0.72, 0)))
        ..strokeWidth = s * 0.055
        ..strokeCap = StrokeCap.round,
    );

    // ── 信号弧 (relay / 远程控制) ───────────────────────
    final arcP = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = s * 0.03;

    for (int i = 0; i < 3; i++) {
      arcP.color = Colors.white.withAlpha(180 - i * 50);
      final radius = s * (0.08 + i * 0.065);
      canvas.drawArc(
        Rect.fromCenter(center: Offset(s * 0.72, s * 0.30), width: radius * 2, height: radius * 2),
        -pi * 0.45,
        pi * 0.4,
        false,
        arcP,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
