import 'dart:ui';

import 'ball_detector.dart';
import 'goal_detector.dart';
import 'goal_gate.dart';
import 'vision.dart';

/// 每幀的狀態，給畫面顯示。座標是畫面寬高為 1 的比例。
class PipelineStatus {
  const PipelineStatus({
    required this.fps,
    required this.inferenceMs,
    required this.prepareMs,
    required this.backend,
    required this.frameSize,
    required this.roiSize,
    required this.ball,
    required this.netMotion,
  });

  final double fps;
  final int inferenceMs;
  final int prepareMs;
  final String backend;
  final Size frameSize;
  final Size roiSize;
  final Offset? ball;
  final double netMotion;
}

/// 手機籃網晃動門檻。門檻跟著「相鄰兩幀隔多久」變，所以和電腦上跑 60fps 的值不同。
const phoneGoalConfig = GoalConfig();

/// 相機畫面 → 找球 → 進球判定。一次處理一張，還沒做完就丟掉新來的畫面。
class GoalPipeline {
  GoalPipeline({required this.rimNorm, required this.detector, required this.onGoal, required this.onStatus});

  final Rect rimNorm; // 比例座標（0～1），正立畫面
  final BallDetector detector;
  final void Function(GoalEvent) onGoal;
  final void Function(PipelineStatus) onStatus;

  GoalDetector? _goal;
  NetMotion? _net;
  Rect? _rim;
  Ball? _prev;
  bool _busy = false;
  final _clock = Stopwatch()..start();
  double _fps = 0;
  double _lastDone = 0;

  /// [upsideDown]：手機橫向反過來拿，感光元件的畫面是倒的。
  Future<void> onFrame(YuvFrame f, {required bool upsideDown}) async {
    if (_busy) return;
    _busy = true;
    try {
      final w = f.width.toDouble(), h = f.height.toDouble();
      final rim = _rim ??= Rect.fromLTRB(rimNorm.left * w, rimNorm.top * h, rimNorm.right * w, rimNorm.bottom * h);
      _goal ??= GoalDetector(rim, phoneGoalConfig);
      _net ??= NetMotion(netRegion(rim));

      final roi = detectionRoi(rim).intersect(Rect.fromLTWH(0, 0, w, h));
      final x0 = roi.left.floor(), y0 = roi.top.floor();
      final cw = roi.width.ceil().clamp(1, f.width - x0), ch = roi.height.ceil().clamp(1, f.height - y0);

      final t = _clock.elapsedMicroseconds / 1e6;
      final rgb = cropRgb(f, x0, y0, cw, ch, upsideDown: upsideDown);
      final result = await detector.detect(rgb, cw, ch);

      final balls = [
        for (final b in result.boxes) Ball(b[0] + x0, b[1] + y0, b[2], b[3], b[4]),
      ];
      final ball = pickBall(balls, _prev);
      _prev = ball;
      final motion = _net!.update(f, ball, upsideDown: upsideDown);
      final ev = _goal!.update(t, ball, motion);
      if (ev != null) onGoal(ev);

      final now = _clock.elapsedMicroseconds / 1e6;
      final dt = now - _lastDone;
      _lastDone = now;
      if (dt > 0) _fps = _fps == 0 ? 1 / dt : _fps * 0.9 + (1 / dt) * 0.1;
      onStatus(PipelineStatus(
        fps: _fps,
        inferenceMs: result.inferenceMs,
        prepareMs: result.prepareMs,
        backend: detector.backend,
        frameSize: Size(w, h),
        roiSize: Size(cw.toDouble(), ch.toDouble()),
        ball: ball == null ? null : Offset(ball.cx / w, ball.cy / h),
        netMotion: motion,
      ));
    } finally {
      _busy = false;
    }
  }
}
