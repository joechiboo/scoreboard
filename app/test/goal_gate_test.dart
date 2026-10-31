import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreboard_detector/services/game_service.dart';
import 'package:scoreboard_detector/services/goal_gate.dart';

void main() {
  test('冷卻期間的進球被忽略，冷卻後恢復', () {
    var now = DateTime(2026, 1, 1, 12);
    final gate = GoalGate(cooldown: const Duration(seconds: 2), now: () => now);
    expect(gate.tryPass(), isTrue);
    now = now.add(const Duration(milliseconds: 1500));
    expect(gate.tryPass(), isFalse);
    now = now.add(const Duration(milliseconds: 600));
    expect(gate.tryPass(), isTrue);
  });

  test('偵測區由籃框寬度往上下左右延伸', () {
    final roi = detectionRoi(const Rect.fromLTRB(300, 200, 400, 220));
    expect(roi, const Rect.fromLTRB(240, -50, 460, 380));
  });

  test('籃框對應隊伍與資料庫 trigger 規則一致', () {
    LiveGame game(bool swapped) =>
        LiveGame(id: 'g', teamAName: '主隊', teamBName: '客隊', sidesSwapped: swapped, mode: 'full');
    expect(game(false).teamNameForHoop(1), '主隊');
    expect(game(false).teamNameForHoop(2), '客隊');
    expect(game(true).teamNameForHoop(1), '客隊');
    expect(game(true).teamNameForHoop(2), '主隊');
    expect(game(false).autoPoints, 2);
  });

  test('半場沒有固定隊伍，自動進球 1 分', () {
    final game = LiveGame(id: 'g', teamAName: '主隊', teamBName: '客隊', sidesSwapped: false, mode: 'half');
    expect(game.teamNameForHoop(1), isNull);
    expect(game.autoPoints, 1);
  });
}
