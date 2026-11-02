import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreboard_detector/services/goal_detector.dart';
import 'package:scoreboard_detector/services/goal_gate.dart';
import 'package:scoreboard_detector/services/vision.dart';

const rim = Rect.fromLTRB(300, 200, 400, 220);
const d = 53.0;
const fps = 30.0;

Ball b(double x, double y, [double size = d]) => Ball(x, y, size, size, 0.8);

/// 沿直線等速移動。
List<(double, Ball?)> line(List<List<double>> pts, double dur, {double size = d, double t0 = 0}) {
  final n = (dur * fps).toInt();
  final segs = pts.length - 1;
  return [
    for (var i = 0; i < n; i++)
      () {
        final u = i / (n - 1) * segs;
        final k = u.floor().clamp(0, segs - 1);
        final f = u - k;
        final x = pts[k][0] + f * (pts[k + 1][0] - pts[k][0]);
        final y = pts[k][1] + f * (pts[k + 1][1] - pts[k][1]);
        return (t0 + i / fps, b(x, y, size) as Ball?);
      }(),
  ];
}

List<GoalEvent> run(List<(double, Ball?)> frames, {GoalConfig cfg = const GoalConfig(), double net = 0.12}) {
  final det = GoalDetector(rim, cfg);
  final events = <GoalEvent>[];
  var below = false;
  for (final (t, ball) in frames) {
    if (ball != null && ball.cy > rim.bottom) below = true;
    final e = det.update(t, ball, below ? net : 0);
    if (e != null) events.add(e);
  }
  final last = frames.last.$1;
  for (var i = 1; i < fps; i++) {
    final e = det.update(last + i / fps, null, below ? net : 0);
    if (e != null) events.add(e);
  }
  return events;
}

const made = [
  [280.0, 40.0],
  [350.0, 205.0],
  [350.0, 330.0],
];

void main() {
  group('進球判定（與 ml/tests/test_goal_detector.py 對應）', () {
    test('進球', () => expect(run(line(made, 0.6)).length, 1));
    test('球往上穿過框不算', () => expect(run(line(made.reversed.toList(), 0.6)), isEmpty));
    test('球從框旁邊掉下不算', () {
      expect(run(line([[450, 40], [460, 205], [460, 330]], 0.6)), isEmpty);
    });
    test('框前的麵包球看起來大，不算', () => expect(run(line(made, 0.6, size: 90)), isEmpty));
    test('框後的麵包球看起來小，不算', () => expect(run(line(made, 0.6, size: 28)), isEmpty));
    test('籃網沒晃不算', () {
      expect(run(line(made, 0.6), net: 0), isEmpty);
      expect(run(line(made, 0.6), net: 0, cfg: const GoalConfig(useNet: false)).length, 1);
    });
    test('上下間隔太久不算', () {
      expect(run([(0.0, b(350, 150)), (1.5, b(350, 280))]), isEmpty);
    });
    test('冷卻期間不重複計分', () {
      expect(run([...line(made, 0.6), ...line(made, 0.6, t0: 1.0)]).length, 1);
    });
    test('冷卻過後第二球算', () {
      expect(run([...line(made, 0.6), ...line(made, 0.6, t0: 3.0)]).length, 2);
    });

    test('球在網裡看不到時籃網晃，往回看得到', () {
      final det = GoalDetector(rim);
      final events = <GoalEvent>[];
      void feed(double t, Ball? ball, double net) {
        final e = det.update(t, ball, net);
        if (e != null) events.add(e);
      }

      feed(0, b(350, 120), 0);
      feed(0.1, b(350, 170), 0);
      for (var i = 1; i < 10; i++) {
        final t = 0.1 + i / fps;
        feed(t, null, t > 0.15 && t < 0.45 ? 0.1 : 0);
      }
      feed(0.5, b(352, 300), 0);
      for (var i = 1; i < 30; i++) {
        feed(0.5 + i / fps, null, 0);
      }
      expect(events.length, 1);
      expect(events.single.netMotion, closeTo(0.1, 1e-9));
    });

    test('滾框後在網裡停 0.8 秒也算', () {
      final frames = <(double, Ball?)>[
        (0.0, b(330, 175)),
        (0.2, b(345, 178)),
        for (var i = 1; i < 24; i++) (0.2 + i / fps, null),
        (1.0, b(350, 290)),
      ];
      expect(run(frames, cfg: const GoalConfig(useNet: false)).length, 1);
    });
  });

  group('影像處理', () {
    YuvFrame frame(int w, int h, int Function(int x, int y) luma) {
      final y = Uint8List(w * h);
      for (var r = 0; r < h; r++) {
        for (var c = 0; c < w; c++) {
          y[r * w + c] = luma(c, r);
        }
      }
      final uv = Uint8List((w ~/ 2) * (h ~/ 2))..fillRange(0, (w ~/ 2) * (h ~/ 2), 128);
      return YuvFrame(width: w, height: h, y: y, yStride: w, u: uv, v: uv, uvStride: w ~/ 2, uvPixelStride: 1);
    }

    test('裁切：灰階 YUV 轉成 R=G=B，位置正確', () {
      final f = frame(8, 6, (x, y) => x * 10 + y);
      final rgb = cropRgb(f, 2, 1, 3, 2);
      expect(rgb.sublist(0, 3), [21, 21, 21]);
      expect(rgb.sublist(15, 18), [42, 42, 42]);
    });

    test('裁切：手機反過來拿時轉正', () {
      final f = frame(8, 6, (x, y) => x * 10 + y);
      // 正立座標 (0,0) 對應感光元件的右下角 (7,5)
      expect(cropRgb(f, 0, 0, 1, 1, upsideDown: true).sublist(0, 3), [75, 75, 75]);
    });

    test('Letterbox：直長裁切置中補灰，座標換得回來', () {
      final rgb = Uint8List(10 * 20 * 3)..fillRange(0, 600, 255);
      final lb = Letterbox.from(rgb, 10, 20, 40);
      expect(lb.scale, 2);
      expect(lb.padX, 10);
      expect(lb.padY, 0);
      expect(lb.input[0], closeTo(114 / 255, 1e-6)); // 左上是補的灰
      expect(lb.input[20 * 40 + 20], closeTo(1, 1e-6)); // 中間是原圖（R 通道）
      expect(lb.input[2 * 40 * 40 + 20 * 40 + 20], closeTo(1, 1e-6)); // B 通道排在後面
      expect(lb.toCropX(20), 5);
      expect(lb.toCropY(20), 10);
    });

    test('解析 YOLO 輸出：只取籃球、門檻、NMS', () {
      const n = 3;
      final out = Float32List(84 * n);
      void box(int i, double x, double y, double w, double h, double score) {
        out[i] = x;
        out[n + i] = y;
        out[2 * n + i] = w;
        out[3 * n + i] = h;
        out[(4 + sportsBallClass) * n + i] = score;
      }

      box(0, 0.5, 0.5, 0.1, 0.1, 0.9);
      box(1, 0.5, 0.5, 0.1, 0.1, 0.4); // 同一顆，NMS 掉
      box(2, 0.2, 0.2, 0.1, 0.1, 0.01); // 低於門檻
      out[(4 + 0) * n + 2] = 0.99; // 別的類別分數高也不算
      final r = parseYolo(out, n, 320, 0.05);
      expect(r.length, 1);
      expect(r.single[0], closeTo(160, 1e-3));
      expect(r.single[4], closeTo(0.9, 1e-6));
    });

    test('選球：沒有上一幀取信心最高，有上一幀取最近', () {
      const near = Ball(10, 10, 5, 5, 0.3), far = Ball(100, 100, 5, 5, 0.6);
      expect(pickBall([near, far], null), far);
      expect(pickBall([near, far], const Ball(12, 12, 5, 5)), near);
      expect(pickBall([], null), isNull);
    });

    test('籃網晃動：畫面不變是 0，網區變了才有值；球的位置遮掉', () {
      const region = Rect.fromLTRB(0, 0, 40, 40);
      final net = NetMotion(region);
      final a = frame(40, 40, (x, y) => 100);
      final c = frame(40, 40, (x, y) => 151);
      expect(net.update(a, null), 0);
      expect(net.update(a, null), 0);
      expect(net.update(c, null), closeTo(51 / 255, 1e-5));
      final masked = NetMotion(region);
      masked.update(a, null);
      expect(masked.update(c, const Ball(20, 20, 200, 200)), 0);
    });

    test('籃網區在框正下方，與 Python 相同', () {
      expect(netRegion(rim), const Rect.fromLTRB(300, 220, 400, 320));
    });
  });
}
