import 'package:flutter/material.dart';

import '../services/goal_gate.dart';

/// 疊在鏡頭畫面上：拖曳框選籃框，並顯示由框推出的偵測區。
/// 座標以畫面寬高為 1 的比例傳出。
class RimSelector extends StatefulWidget {
  const RimSelector({super.key, required this.rim, required this.editing, required this.onChanged});

  final Rect? rim;
  final bool editing;
  final ValueChanged<Rect> onChanged;

  @override
  State<RimSelector> createState() => _RimSelectorState();
}

class _RimSelectorState extends State<RimSelector> {
  Offset? _start;
  Rect? _drag;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      Offset norm(Offset p) => Offset((p.dx / size.width).clamp(0, 1), (p.dy / size.height).clamp(0, 1));

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: widget.editing ? (d) => setState(() => _start = norm(d.localPosition)) : null,
        onPanUpdate: widget.editing
            ? (d) => setState(() => _drag = Rect.fromPoints(_start!, norm(d.localPosition)))
            : null,
        onPanEnd: widget.editing
            ? (_) {
                final r = _drag;
                setState(() => _drag = _start = null);
                if (r != null && r.width > 0.02 && r.height > 0.005) widget.onChanged(r);
              }
            : null,
        child: CustomPaint(
          size: size,
          painter: _RimPainter(rim: _drag ?? widget.rim, editing: widget.editing),
        ),
      );
    });
  }
}

class _RimPainter extends CustomPainter {
  _RimPainter({required this.rim, required this.editing});

  final Rect? rim;
  final bool editing;

  static const rimColor = Color(0xFFFF7A33);
  static const roiColor = Color(0xFF6EA2FF);

  @override
  void paint(Canvas canvas, Size size) {
    final r = rim;
    if (r == null) return;
    Rect px(Rect n) => Rect.fromLTRB(n.left * size.width, n.top * size.height, n.right * size.width, n.bottom * size.height);

    // 以像素計算偵測區，才能用籃框「寬度」當單位往上下延伸
    final rimPx = px(r);
    final roiPx = detectionRoi(rimPx).intersect(Offset.zero & size);

    // 偵測區外變暗
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(roiPx),
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );
    canvas.drawRect(roiPx, Paint()
      ..color = roiColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    canvas.drawRect(rimPx, Paint()
      ..color = rimColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = editing ? 3 : 2);
  }

  @override
  bool shouldRepaint(_RimPainter old) => old.rim != rim || old.editing != editing;
}
