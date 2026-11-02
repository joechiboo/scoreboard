import 'package:flutter/material.dart';

import '../services/game_service.dart';
import '../services/goal_reporter.dart';
import '../services/settings.dart';
import 'camera_screen.dart';

const setupSteps = [
  '先架好手機：橫拿放上腳架，架高，籃框要完整入鏡且不被擋住，寬度至少佔畫面 1/20。打球時不要碰到腳架。',
  '選全場或半場。半場只要一支手機，不用選籃框；全場每個籃框各一支手機。',
  '按「開始偵測」。',
  '照著鐵圈框住籃框，按「完成」。上次的框還在的話，按「重新框選」再框一次。',
  '畫面上方出現「找球 fps」就開始偵測了，球經過時會畫黃圈。',
  '腳架動到就要重新框選，否則會對著錯的位置偵測。',
];

/// 比這個寬（橫拿的手機、平板）就分成左右兩欄，「開始偵測」才不會被擠到畫面外。
const twoColumnWidth = 640.0;

/// 選模式與籃框，並顯示目前比賽與架設步驟。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.settings, required this.games, required this.reporter});

  final Settings settings;
  final GameService games;
  final GoalReporter reporter;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late int _hoop = widget.settings.hoop;
  bool _switching = false;

  Future<void> _setMode(LiveGame game, String mode) async {
    setState(() => _switching = true);
    try {
      await widget.games.setMode(game.id, mode);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('切換失敗，請檢查網路')));
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('進球偵測')),
      body: StreamBuilder<LiveGame?>(
        stream: widget.games.stream,
        initialData: widget.games.current,
        builder: (context, snap) => HomeLayout(
          controls: _controls(context, snap.data),
          steps: const SetupSteps(),
          action: _startButton(context),
        ),
      ),
    );
  }

  List<Widget> _controls(BuildContext context, LiveGame? game) {
    final theme = Theme.of(context);
    final half = game?.isHalfCourt ?? false;
    return [
      Text('模式', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'half', label: Text('半場（3v3）')),
          ButtonSegment(value: 'full', label: Text('全場')),
        ],
        selected: {game?.mode ?? 'full'},
        onSelectionChanged: game == null || _switching ? null : (s) => _setMode(game, s.first),
      ),
      const SizedBox(height: 20),
      if (!half) ...[
        Text('這支手機對著哪個籃框？', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 1, label: Text('1 號籃框')),
            ButtonSegment(value: 2, label: Text('2 號籃框')),
          ],
          selected: {_hoop},
          onSelectionChanged: (s) => setState(() => widget.settings.hoop = _hoop = s.first),
        ),
        const SizedBox(height: 20),
      ],
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: game == null
              ? const Text('連線中，或目前沒有進行中的比賽')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('目前比賽（${half ? '半場' : '全場'}）：${game.teamAName} vs ${game.teamBName}'),
                    const SizedBox(height: 8),
                    Text(
                      half ? '進球 +${game.autoPoints}，在計分板選擇隊伍' : '進球會記給「${game.teamNameForHoop(_hoop)}」',
                      style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.primary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      half ? '半場兩隊投同一個籃框，只需要一支手機' : '換場對調在計分板網頁上操作，這裡會自動更新',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
        ),
      ),
    ];
  }

  Widget _startButton(BuildContext context) => FilledButton.icon(
        icon: const Icon(Icons.videocam),
        label: const Text('開始偵測'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => CameraScreen(
            settings: widget.settings,
            games: widget.games,
            reporter: widget.reporter,
          ),
        )),
      );
}

/// 直拿一欄往下捲；橫拿或平板分成左右兩欄，各自捲動。「開始偵測」固定在底部，不用捲就按得到。
class HomeLayout extends StatelessWidget {
  const HomeLayout({super.key, required this.controls, required this.steps, required this.action});

  final List<Widget> controls;
  final Widget steps;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: LayoutBuilder(builder: (context, c) {
        const pad = EdgeInsets.fromLTRB(20, 8, 20, 12);
        return Column(
          children: [
            Expanded(
              child: c.maxWidth >= twoColumnWidth
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: ListView(padding: pad, children: controls)),
                        Expanded(child: ListView(padding: pad, children: [steps])),
                      ],
                    )
                  : ListView(padding: pad, children: [...controls, const SizedBox(height: 24), steps]),
            ),
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 12), child: action),
          ],
        );
      }),
    );
  }
}

class SetupSteps extends StatelessWidget {
  const SetupSteps({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('架設步驟', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final (i, step) in setupSteps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(radius: 12, child: Text('${i + 1}', style: const TextStyle(fontSize: 13))),
                const SizedBox(width: 12),
                Expanded(child: Text(step, style: theme.textTheme.bodyMedium)),
              ],
            ),
          ),
      ],
    );
  }
}
