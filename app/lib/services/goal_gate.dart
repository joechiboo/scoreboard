import 'dart:ui';

import '../config.dart';

/// 由籃框框選框推出偵測區（與 ml/scoreboard_ml/geometry.py 的 detection_roi 相同），
/// 倍數以籃框寬度為單位：往上看球飛進來、往下看球從網子掉出。
Rect detectionRoi(Rect rim, {double up = 2.5, double down = 1.6, double side = 0.6}) {
  final w = rim.width;
  return Rect.fromLTRB(rim.left - side * w, rim.top - up * w, rim.right + side * w, rim.bottom + down * w);
}

/// 判定後冷卻：冷卻期間的進球一律忽略。
class GoalGate {
  GoalGate({this.cooldown = goalCooldown, DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Duration cooldown;
  final DateTime Function() _now;
  DateTime? _last;

  bool get coolingDown => _last != null && _now().difference(_last!) < cooldown;

  /// 回傳 true 表示這次進球有效。
  bool tryPass() {
    if (coolingDown) return false;
    _last = _now();
    return true;
  }
}
