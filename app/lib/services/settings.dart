import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';

/// 這支手機的設定：對應哪個籃框、籃框框選位置。
class Settings {
  Settings._(this._prefs);

  final SharedPreferences _prefs;

  static Future<Settings> load() async => Settings._(await SharedPreferences.getInstance());

  int get hoop => _prefs.getInt('hoop') ?? 1;
  set hoop(int v) => _prefs.setInt('hoop', v);

  /// 籃框框選框，以鏡頭畫面寬高為 1 的比例座標儲存，換解析度也適用。
  Rect? get rimBox {
    final v = _prefs.getStringList('rim_box');
    if (v == null || v.length != 4) return null;
    final n = v.map(double.parse).toList();
    return Rect.fromLTRB(n[0], n[1], n[2], n[3]);
  }

  set rimBox(Rect? r) => r == null
      ? _prefs.remove('rim_box')
      : _prefs.setStringList('rim_box', [r.left, r.top, r.right, r.bottom].map((e) => e.toString()).toList());
}
