import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'goal_detector.dart';

/// 相機畫面（與 camera 套件的 CameraImage 對應，抽出來才能單獨測試）。
class YuvFrame {
  const YuvFrame({
    required this.width,
    required this.height,
    required this.y,
    required this.yStride,
    required this.u,
    required this.v,
    required this.uvStride,
    required this.uvPixelStride,
  });

  final int width, height;
  final Uint8List y, u, v;
  final int yStride, uvStride, uvPixelStride;
}

/// 從畫面裁出一塊 RGB。座標是「正立」的畫面座標；手機橫向反過來拿時
/// （upsideDown）感光元件的畫面是倒的，這裡轉正，後面的判定都不用管方向。
Uint8List cropRgb(YuvFrame f, int x0, int y0, int w, int h, {bool upsideDown = false}) {
  final out = Uint8List(w * h * 3);
  var o = 0;
  for (var row = 0; row < h; row++) {
    for (var col = 0; col < w; col++) {
      final sx = upsideDown ? f.width - 1 - (x0 + col) : x0 + col;
      final sy = upsideDown ? f.height - 1 - (y0 + row) : y0 + row;
      final yv = f.y[sy * f.yStride + sx];
      final uvi = (sy >> 1) * f.uvStride + (sx >> 1) * f.uvPixelStride;
      final u = f.u[uvi] - 128;
      final v = f.v[uvi] - 128;
      out[o++] = (yv + 1.402 * v).round().clamp(0, 255);
      out[o++] = (yv - 0.344 * u - 0.714 * v).round().clamp(0, 255);
      out[o++] = (yv + 1.772 * u).round().clamp(0, 255);
    }
  }
  return out;
}

/// 把 RGB 等比例放大到 size×size，不足的地方補灰（與 YOLO 的前處理相同），用雙線性內插。
class Letterbox {
  Letterbox(this.input, this.scale, this.padX, this.padY);

  final Float32List input; // 0～1，通道在前 [3, size, size]（Ultralytics 匯出的 LiteRT 模型）
  final double scale, padX, padY;

  static Letterbox from(Uint8List rgb, int w, int h, int size) {
    final scale = size / math.max(w, h);
    final nw = (w * scale).round(), nh = (h * scale).round();
    final padX = (size - nw) ~/ 2, padY = (size - nh) ~/ 2;
    final out = Float32List(size * size * 3)..fillRange(0, size * size * 3, 114 / 255);
    for (var y = 0; y < nh; y++) {
      final sy = (y + 0.5) / scale - 0.5;
      final y0 = sy.floor().clamp(0, h - 1), y1 = (y0 + 1).clamp(0, h - 1);
      final fy = (sy - y0).clamp(0.0, 1.0);
      for (var x = 0; x < nw; x++) {
        final sx = (x + 0.5) / scale - 0.5;
        final x0 = sx.floor().clamp(0, w - 1), x1 = (x0 + 1).clamp(0, w - 1);
        final fx = (sx - x0).clamp(0.0, 1.0);
        final o = (y + padY) * size + x + padX;
        for (var c = 0; c < 3; c++) {
          final a = rgb[(y0 * w + x0) * 3 + c] * (1 - fx) + rgb[(y0 * w + x1) * 3 + c] * fx;
          final b = rgb[(y1 * w + x0) * 3 + c] * (1 - fx) + rgb[(y1 * w + x1) * 3 + c] * fx;
          out[c * size * size + o] = (a * (1 - fy) + b * fy) / 255;
        }
      }
    }
    return Letterbox(out, scale, padX.toDouble(), padY.toDouble());
  }

  /// 模型輸入座標 → 裁切區座標。
  double toCropX(double x) => (x - padX) / scale;
  double toCropY(double y) => (y - padY) / scale;
}

const sportsBallClass = 32; // COCO 的 sports ball

/// 解析 YOLO TFLite 輸出 [1, 84, N]（依通道排列）：中心 x、y、寬、高（0～1，相對於輸入）
/// 接 80 類分數。只看 sports ball，做簡單的 NMS。回傳輸入座標（像素）的 [cx, cy, w, h, conf]。
List<List<double>> parseYolo(Float32List out, int n, int inputSize, double conf) {
  final found = <List<double>>[];
  for (var i = 0; i < n; i++) {
    final score = out[(4 + sportsBallClass) * n + i];
    if (score < conf) continue;
    found.add([
      out[i] * inputSize,
      out[n + i] * inputSize,
      out[2 * n + i] * inputSize,
      out[3 * n + i] * inputSize,
      score,
    ]);
  }
  found.sort((a, b) => b[4].compareTo(a[4]));
  final kept = <List<double>>[];
  for (final b in found) {
    if (kept.every((k) => _iou(k, b) < 0.5)) kept.add(b);
  }
  return kept;
}

double _iou(List<double> a, List<double> b) {
  final x1 = math.max(a[0] - a[2] / 2, b[0] - b[2] / 2), x2 = math.min(a[0] + a[2] / 2, b[0] + b[2] / 2);
  final y1 = math.max(a[1] - a[3] / 2, b[1] - b[3] / 2), y2 = math.min(a[1] + a[3] / 2, b[1] + b[3] / 2);
  if (x2 <= x1 || y2 <= y1) return 0;
  final inter = (x2 - x1) * (y2 - y1);
  return inter / (a[2] * a[3] + b[2] * b[3] - inter);
}

/// 有上一幀時選最近的那顆，避免在兩顆球之間跳來跳去（與 ball_detector.py 相同）。
Ball? pickBall(List<Ball> balls, Ball? prev) {
  if (balls.isEmpty) return null;
  if (prev == null) return balls.reduce((a, b) => a.conf >= b.conf ? a : b);
  double key(Ball b) {
    final dx = b.cx - prev.cx, dy = b.cy - prev.cy;
    return math.sqrt(dx * dx + dy * dy) / math.max(b.conf, 1e-3);
  }

  return balls.reduce((a, b) => key(a) <= key(b) ? a : b);
}

/// 籃網晃動量：籃網區相鄰兩幀的平均差異（0～1），球所在的位置遮掉。
/// 先縮到固定大小再模糊，不同解析度的手機才能用同一個門檻。
class NetMotion {
  NetMotion(this.region, {this.ballPad = 0.3});

  static const grid = 51;
  static const _kernel = [1, 4, 6, 4, 1];

  final Rect region;
  final double ballPad;
  Float32List? _prev;
  Ball? _prevBall;

  double update(YuvFrame f, Ball? ball, {bool upsideDown = false}) {
    final cur = _sample(f, upsideDown);
    final prev = _prev;
    final prevBall = _prevBall;
    _prev = cur;
    _prevBall = ball;
    if (prev == null) return 0;

    final sx = grid / region.width, sy = grid / region.height;
    final mask = Uint8List(grid * grid);
    for (final b in [ball, prevBall]) {
      if (b == null) continue;
      final pad = b.diameter * ballPad;
      final x1 = ((b.cx - b.w / 2 - pad - region.left) * sx).floor().clamp(0, grid);
      final x2 = ((b.cx + b.w / 2 + pad - region.left) * sx).ceil().clamp(0, grid);
      final y1 = ((b.cy - b.h / 2 - pad - region.top) * sy).floor().clamp(0, grid);
      final y2 = ((b.cy + b.h / 2 + pad - region.top) * sy).ceil().clamp(0, grid);
      for (var y = y1; y < y2; y++) {
        for (var x = x1; x < x2; x++) {
          mask[y * grid + x] = 1;
        }
      }
    }
    var sum = 0.0;
    var n = 0;
    for (var i = 0; i < grid * grid; i++) {
      if (mask[i] == 1) continue;
      sum += (cur[i] - prev[i]).abs();
      n++;
    }
    return n == 0 ? 0 : sum / n;
  }

  Float32List _sample(YuvFrame f, bool upsideDown) {
    final raw = Float32List(grid * grid);
    // 每格取區塊平均（畫面解析度高時等於 area 縮圖）
    final cw = region.width / grid, ch = region.height / grid;
    for (var gy = 0; gy < grid; gy++) {
      final y0 = (region.top + gy * ch).floor(), y1 = math.max(y0 + 1, (region.top + (gy + 1) * ch).ceil());
      for (var gx = 0; gx < grid; gx++) {
        final x0 = (region.left + gx * cw).floor(), x1 = math.max(x0 + 1, (region.left + (gx + 1) * cw).ceil());
        var sum = 0, n = 0;
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            final px = (upsideDown ? f.width - 1 - x : x).clamp(0, f.width - 1);
            final py = (upsideDown ? f.height - 1 - y : y).clamp(0, f.height - 1);
            sum += f.y[py * f.yStride + px];
            n++;
          }
        }
        raw[gy * grid + gx] = sum / n / 255;
      }
    }
    return _blur(raw);
  }

  static Float32List _blur(Float32List src) {
    final tmp = Float32List(grid * grid), out = Float32List(grid * grid);
    for (var y = 0; y < grid; y++) {
      for (var x = 0; x < grid; x++) {
        var s = 0.0;
        for (var k = -2; k <= 2; k++) {
          s += src[y * grid + (x + k).clamp(0, grid - 1)] * _kernel[k + 2];
        }
        tmp[y * grid + x] = s / 16;
      }
    }
    for (var y = 0; y < grid; y++) {
      for (var x = 0; x < grid; x++) {
        var s = 0.0;
        for (var k = -2; k <= 2; k++) {
          s += tmp[(y + k).clamp(0, grid - 1) * grid + x] * _kernel[k + 2];
        }
        out[y * grid + x] = s / 16;
      }
    }
    return out;
  }
}
