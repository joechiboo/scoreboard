import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// 目前進行中的比賽（只取 App 需要的欄位）。
class LiveGame {
  LiveGame({
    required this.id,
    required this.teamAName,
    required this.teamBName,
    required this.sidesSwapped,
    required this.mode,
  });

  final String id;
  final String teamAName;
  final String teamBName;
  final bool sidesSwapped;

  /// 'full' 全場：兩個籃框各對應一隊；'half' 半場：進球由計分板選隊伍。
  final String mode;

  bool get isHalfCourt => mode == 'half';

  /// 自動進球的分數（與資料庫 trigger 一致）：全場 2 分、半場 1 分。
  int get autoPoints => isHalfCourt ? 1 : 2;

  factory LiveGame.fromRow(Map<String, dynamic> row) => LiveGame(
        id: row['id'] as String,
        teamAName: row['team_a_name'] as String,
        teamBName: row['team_b_name'] as String,
        sidesSwapped: row['sides_swapped'] as bool? ?? false,
        mode: row['mode'] as String? ?? 'full',
      );

  /// 這個籃框目前對應的隊名（與資料庫 trigger 的規則一致）；半場沒有固定隊伍，回傳 null。
  String? teamNameForHoop(int hoop) {
    if (isHalfCourt) return null;
    return (hoop == 1) != sidesSwapped ? teamAName : teamBName;
  }
}

/// 追蹤目前進行中的比賽：開新局、換場對調時自動更新。
class GameService {
  GameService(this._client);

  final SupabaseClient _client;
  final _controller = StreamController<LiveGame?>.broadcast();
  RealtimeChannel? _channel;
  LiveGame? current;

  Stream<LiveGame?> get stream => _controller.stream;

  Future<LiveGame?> fetch() async {
    final row = await _client
        .from('games')
        .select()
        .eq('status', 'live')
        .maybeSingle();
    current = row == null ? null : LiveGame.fromRow(row);
    _controller.add(current);
    return current;
  }

  void start() {
    _channel ??= _client
        .channel('detector:games')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'games',
          callback: (_) => fetch(),
        )
        .subscribe((status, _) {
          if (status == RealtimeSubscribeStatus.subscribed) fetch();
        });
  }

  Future<void> dispose() async {
    if (_channel != null) await _client.removeChannel(_channel!);
    await _controller.close();
  }
}
