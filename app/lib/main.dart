import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'screens/home_screen.dart';
import 'services/game_service.dart';
import 'services/goal_reporter.dart';
import 'services/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, publishableKey: supabaseKey);

  final client = Supabase.instance.client;
  final settings = await Settings.load();
  final games = GameService(client)..start();
  final reporter = GoalReporter(client, games);
  await reporter.init();

  runApp(DetectorApp(settings: settings, games: games, reporter: reporter));
}

class DetectorApp extends StatelessWidget {
  const DetectorApp({super.key, required this.settings, required this.games, required this.reporter});

  final Settings settings;
  final GameService games;
  final GoalReporter reporter;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '進球偵測',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFF7A33), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: HomeScreen(settings: settings, games: games, reporter: reporter),
    );
  }
}
