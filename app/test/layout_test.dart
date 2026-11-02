import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scoreboard_detector/screens/home_screen.dart';
import 'package:scoreboard_detector/widgets/rim_hint.dart';

/// 各種螢幕大小與方向（寬 × 高，邏輯像素）。版面溢位時 Flutter 會丟例外，測試就會失敗。
const sizes = {
  '小手機直拿': Size(320, 568),
  '小手機橫拿': Size(568, 320),
  'S23 直拿': Size(360, 780),
  'S23 橫拿': Size(780, 360),
  '平板直拿': Size(800, 1280),
  '平板橫拿': Size(1280, 800),
};

Future<void> pump(WidgetTester tester, Size size, Widget child) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  for (final MapEntry(key: name, value: size) in sizes.entries) {
    testWidgets('首頁 $name：不溢位，分欄正確', (tester) async {
      await pump(
        tester,
        size,
        HomeLayout(
          controls: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'half', label: Text('半場（3v3）')),
                ButtonSegment(value: 'full', label: Text('全場')),
              ],
              selected: const {'full'},
              onSelectionChanged: (_) {},
            ),
          ],
          steps: const SetupSteps(),
          action: const SizedBox(height: 52, child: Text('開始偵測')),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(ListView), findsNWidgets(size.width >= twoColumnWidth ? 2 : 1));
      // 不用捲動，開始偵測就在畫面內
      expect(tester.getBottomLeft(find.text('開始偵測')).dy, lessThanOrEqualTo(size.height));
    });

    testWidgets('框選示意圖 $name：不溢位', (tester) async {
      await pump(
        tester,
        size,
        Align(alignment: Alignment.centerLeft, child: RimHint(onClose: () {})),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('照著鐵圈框'), findsOneWidget);
    });
  }

  testWidgets('示意圖的關閉鍵在最矮的畫面也按得到', (tester) async {
    var closed = false;
    await pump(
      tester,
      const Size(568, 200),
      Align(alignment: Alignment.centerLeft, child: RimHint(onClose: () => closed = true)),
    );
    await tester.tap(find.byIcon(Icons.close));
    expect(closed, isTrue);
  });
}
