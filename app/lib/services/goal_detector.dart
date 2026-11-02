import 'dart:collection';
import 'dart:ui';

/// 進球判定：與 ml/scoreboard_ml/goal_detector.py 相同的邏輯，改動要兩邊一起改。
///
/// 1. 軌跡：球先出現在框上方，maxTransit 內出現在框下方，且兩點連線穿過框內
/// 2. 大小：穿越時球徑 / 框寬 接近 24cm / 45cm
/// 3. 籃網晃動：從球在框上方起，到穿越後 netWindow 內，籃網區要有明顯變化
///    （球在網裡常被擋住偵測不到，籃網晃最大的時候往往在球從網下出現之前）
const ballToRimRatio = 24 / 45;

class Ball {
  const Ball(this.cx, this.cy, this.w, this.h, [this.conf = 1.0]);

  final double cx, cy, w, h, conf;

  double get diameter => (w + h) / 2;
}

class GoalConfig {
  const GoalConfig({
    this.maxTransit = 1.0,
    this.aboveMargin = 0.5,
    this.crossingTol = 0.1,
    this.belowMargin = 0.15,
    this.belowDepth = 1.6,
    this.useSize = true,
    this.expectedRatio = ballToRimRatio,
    this.sizeTol = 0.4,
    this.useNet = true,
    this.netWindow = 0.8,
    this.netThreshold = 0.04,
    this.cooldown = 2.0,
  });

  final double maxTransit; // 從框上方到框下方的最長時間（秒）
  final double aboveMargin; // 「上方」區左右可超出框的寬度（倍數）
  final double crossingTol; // 穿越點可超出框左右的容許量（倍數）
  final double belowMargin; // 「下方」區左右可超出框的寬度（倍數）
  final double belowDepth; // 「下方」區的深度（框寬倍數）
  final bool useSize;
  final double expectedRatio;
  final double sizeTol;
  final bool useNet;
  final double netWindow;
  final double netThreshold;
  final double cooldown;
}

class GoalEvent {
  const GoalEvent(this.t, this.confidence, this.sizeRatio, this.netMotion);

  final double t; // 穿越籃框的時間（秒）
  final double confidence;
  final double sizeRatio;
  final double? netMotion;
}

class _Pending {
  _Pending(this.event, this.deadline, this.peak);

  final GoalEvent event;
  final double deadline;
  double peak;
}

class GoalDetector {
  GoalDetector(this.rim, [this.cfg = const GoalConfig()]);

  final Rect rim;
  final GoalConfig cfg;

  double? _aboveT;
  Ball? _above;
  _Pending? _pending;
  double _cooldownUntil = double.negativeInfinity;
  final _motion = Queue<(double, double)>();

  bool _isAbove(Ball b) {
    final m = cfg.aboveMargin * rim.width;
    return b.cy < rim.top && b.cx >= rim.left - m && b.cx <= rim.right + m;
  }

  bool _isBelow(Ball b) {
    final m = cfg.belowMargin * rim.width;
    return b.cy > rim.bottom &&
        b.cy <= rim.bottom + cfg.belowDepth * rim.width &&
        b.cx >= rim.left - m &&
        b.cx <= rim.right + m;
  }

  bool _crossesRim(Ball a, Ball b) {
    if (b.cy == a.cy) return false;
    final k = (rim.center.dy - a.cy) / (b.cy - a.cy);
    final x = a.cx + k * (b.cx - a.cx);
    final tol = cfg.crossingTol * rim.width;
    return x >= rim.left - tol && x <= rim.right + tol;
  }

  bool _sizeOk(double ratio) {
    if (!cfg.useSize) return true;
    return ratio >= cfg.expectedRatio * (1 - cfg.sizeTol) && ratio <= cfg.expectedRatio * (1 + cfg.sizeTol);
  }

  /// 每一幀呼叫一次；回傳確認的進球事件，否則 null。
  GoalEvent? update(double t, Ball? ball, double? netMotion) {
    if (netMotion != null) {
      _motion.addLast((t, netMotion));
      while (_motion.isNotEmpty && _motion.first.$1 < t - cfg.maxTransit) {
        _motion.removeFirst();
      }
    }
    var confirmed = _updatePending(t, netMotion);

    if (ball != null && t >= _cooldownUntil && _pending == null) {
      if (_isAbove(ball)) {
        _aboveT = t;
        _above = ball;
      } else if (_above != null && _isBelow(ball)) {
        final tAbove = _aboveT!;
        final above = _above!;
        if (t - tAbove <= cfg.maxTransit && _crossesRim(above, ball)) {
          _above = _aboveT = null;
          final ratio = (above.diameter + ball.diameter) / 2 / rim.width;
          if (_sizeOk(ratio)) {
            final event = GoalEvent((tAbove + t) / 2, (above.conf + ball.conf) / 2, ratio, null);
            if (cfg.useNet) {
              var peak = 0.0;
              for (final (tt, m) in _motion) {
                if (tt >= tAbove && m > peak) peak = m;
              }
              _pending = _Pending(event, t + cfg.netWindow, peak);
              confirmed ??= _updatePending(t, netMotion);
            } else {
              confirmed = _confirm(event, t);
            }
          }
        }
      }
    }

    if (_aboveT != null && t - _aboveT! > cfg.maxTransit) {
      _above = _aboveT = null;
    }
    return confirmed;
  }

  GoalEvent? _updatePending(double t, double? netMotion) {
    final p = _pending;
    if (p == null) return null;
    if (netMotion != null && netMotion > p.peak) p.peak = netMotion;
    if (p.peak >= cfg.netThreshold) {
      _pending = null;
      return _confirm(GoalEvent(p.event.t, p.event.confidence, p.event.sizeRatio, p.peak), t);
    }
    if (t > p.deadline) _pending = null; // 籃網沒晃：不算
    return null;
  }

  GoalEvent _confirm(GoalEvent e, double t) {
    _cooldownUntil = t + cfg.cooldown;
    _above = _aboveT = null;
    return e;
  }
}
