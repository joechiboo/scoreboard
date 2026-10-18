import 'package:flutter/material.dart';

import '../services/game_service.dart';
import '../services/goal_reporter.dart';
import '../services/settings.dart';
import 'camera_screen.dart';

/// 選這支手機對應哪個籃框，並顯示目前比賽與籃框對應的隊伍。
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('進球偵測')),
      body: StreamBuilder<LiveGame?>(
        stream: widget.games.stream,
        initialData: widget.games.current,
        builder: (context, snap) {
          final game = snap.data;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text('這支手機對著哪個籃框？', style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 1, label: Text('1 號籃框')),
                  ButtonSegment(value: 2, label: Text('2 號籃框')),
                ],
                selected: {_hoop},
                onSelectionChanged: (s) => setState(() => widget.settings.hoop = _hoop = s.first),
              ),
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: game == null
                      ? const Text('連線中，或目前沒有進行中的比賽')
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('目前比賽：${game.teamAName} vs ${game.teamBName}'),
                            const SizedBox(height: 8),
                            Text(
                              '進球會記給「${game.teamNameForHoop(_hoop)}」',
                              style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.primary),
                            ),
                            const SizedBox(height: 4),
                            Text('換場對調在計分板網頁上操作，這裡會自動更新', style: theme.textTheme.bodySmall),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.videocam),
                label: const Text('開始偵測'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => CameraScreen(
                    settings: widget.settings,
                    games: widget.games,
                    reporter: widget.reporter,
                  ),
                )),
              ),
            ],
          );
        },
      ),
    );
  }
}
