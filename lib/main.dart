import 'package:flutter/widgets.dart';
import 'adapter/adapter.dart';
import 'ui/doom_app.dart';
import 'ui/doom_startup.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    DoomStartup(initialize: initializeDoomRenderer, child: const DoomApp()),
  );
}
