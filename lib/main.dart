import 'package:flutter/widgets.dart';

import 'adapter/adapter.dart';
import 'ui/doom_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDoomRenderer();
  runApp(const DoomApp());
}
