import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'game_service.dart';

/// 一筆尚未成功寫入的自動進球。
class PendingGoal {
  PendingGoal({
    required this.clientId,
    required this.hoop,
    required this.confidence,
    required this.detectedAt,
  });

  final String clientId;
  final int hoop;
  final double? confidence;
  final DateTime detectedAt;

  Map<String, dynamic> toJson() => {
        'client_id': clientId,
        'hoop': hoop,
        'confidence': confidence,
        'detected_at': detectedAt.toIso8601String(),
      };

  factory PendingGoal.fromJson(Map<String, dynamic> j) => PendingGoal(
        clientId: j['client_id'] as String,
        hoop: j['hoop'] as int,
        confidence: (j['confidence'] as num?)?.toDouble(),
        detectedAt: DateTime.parse(j['detected_at'] as String),
      );
}

/// 把自動進球寫入 Supabase。
/// - 每筆進球先存到手機，送成功才刪除；斷線時每 5 秒重試
/// - 每筆帶 App 產生的 client_id，重送時資料庫會忽略重複的那筆
/// - 只傳籃框編號，隊伍由資料庫依比賽模式、換場狀態決定
class GoalReporter {
  GoalReporter(this._client, this._games);

  static const _prefsKey = 'pending_goals';

  final SupabaseClient _client;
  final GameService _games;
  final _uuid = const Uuid();
  final _pending = <PendingGoal>[];
  final _status = StreamController<int>.broadcast();
  Timer? _retry;
  bool _flushing = false;

  /// 尚未送出的筆數。
  Stream<int> get pendingCount => _status.stream;
  int get pending => _pending.length;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_prefsKey) ?? [];
    _pending.addAll(saved.map((s) => PendingGoal.fromJson(jsonDecode(s) as Map<String, dynamic>)));
    _retry = Timer.periodic(const Duration(seconds: 5), (_) => flush());
    _status.add(_pending.length);
    unawaited(flush());
  }

  Future<void> report({required int hoop, double? confidence}) async {
    _pending.add(PendingGoal(
      clientId: _uuid.v4(),
      hoop: hoop,
      confidence: confidence,
      detectedAt: DateTime.now(),
    ));
    await _save();
    await flush();
  }

  Future<void> flush() async {
    if (_flushing || _pending.isEmpty) return;
    _flushing = true;
    try {
      while (_pending.isNotEmpty) {
        final goal = _pending.first;
        final game = _games.current ?? await _games.fetch();
        if (game == null) return; // 沒有進行中的比賽，稍後再試
        await _client.from('score_events').upsert(
          {
            'client_id': goal.clientId,
            'game_id': game.id,
            'hoop': goal.hoop,
            // 與資料庫 trigger 的預設相同；明確帶上，舊版資料庫（沒有自動補分數）也能寫入
            'points': game.autoPoints,
            'source': 'auto',
            'confidence': goal.confidence,
          },
          onConflict: 'client_id',
          ignoreDuplicates: true,
        );
        _pending.removeAt(0);
        await _save();
      }
    } catch (_) {
      // 網路錯誤：保留在佇列，等下次重試
    } finally {
      _flushing = false;
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, _pending.map((g) => jsonEncode(g.toJson())).toList());
    _status.add(_pending.length);
  }

  Future<void> dispose() async {
    _retry?.cancel();
    await _status.close();
  }
}
