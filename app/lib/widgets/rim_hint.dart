import 'package:flutter/material.dart';

/// 框選籃框的示意圖：框要貼著鐵圈，不是大概圈一下。
/// 判定用框的左右當籃框寬度、上下線判斷球在框上方或下方，框歪了會直接影響準度。
class RimHint extends StatelessWidget {
  const RimHint({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(12),
      ),
      // 橫拿的畫面很矮，放不下時要能捲動，不能溢位
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '照著鐵圈框',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                tooltip: '收起',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, color: Colors.white70),
                onPressed: onClose,
              ),
            ],
          ),
          const Flexible(
            child: SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.only(right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '左右貼齊鐵圈，上下只框圈本身，不要框到籃板和籃網。',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: _Example(good: true)),
                        SizedBox(width: 8),
                        Expanded(child: _Example(good: false)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Example extends StatelessWidget {
  const _Example({required this.good});

  final bool good;

  @override
  Widget build(BuildContext context) {
    final color = good ? Colors.lightGreenAccent : Colors.redAccent;
    return Column(
      children: [
        AspectRatio(aspectRatio: 1, child: CustomPaint(painter: RimHintPainter(good: good))),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(good ? Icons.check_circle : Icons.cancel, color: color, size: 16),
            const SizedBox(width: 4),
            Text(good ? '這樣對' : '框太大', style: TextStyle(color: color, fontSize: 13)),
          ],
        ),
      ],
    );
  }
}

/// 畫籃板、鐵圈、籃網，再疊上框選框（顏色與實際框線相同）。
class RimHintPainter extends CustomPainter {
  RimHintPainter({required this.good});

  final bool good;

  static const boxColor = Color(0xFFFF7A33);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final line = Paint()
      ..color = Colors.white60
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // 籃板與小方框
    canvas.drawRect(Rect.fromLTRB(w * 0.1, h * 0.08, w * 0.9, h * 0.62), line);
    canvas.drawRect(Rect.fromLTRB(w * 0.34, h * 0.28, w * 0.66, h * 0.55), line);

    // 籃網：從鐵圈往下收窄
    final rimL = w * 0.28, rimR = w * 0.72, rimY = h * 0.58;
    final netL = w * 0.38, netR = w * 0.62, netY = h * 0.9;
    final net = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final k = i / 4;
      canvas.drawLine(Offset(rimL + (rimR - rimL) * k, rimY), Offset(netL + (netR - netL) * k, netY), net);
      canvas.drawLine(Offset(rimL + (rimR - rimL) * k, rimY), Offset(netR - (netR - netL) * k, netY), net);
    }

    // 鐵圈：從下方往上看，是一個很扁的橢圓
    final ring = Rect.fromCenter(center: Offset(w / 2, rimY), width: rimR - rimL, height: h * 0.07);
    canvas.drawOval(
      ring,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // 框選框
    final box = good ? ring.inflate(2) : Rect.fromLTRB(w * 0.06, h * 0.04, w * 0.94, h * 0.95);
    canvas.drawRect(
      box,
      Paint()
        ..color = boxColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(RimHintPainter old) => old.good != good;
}
