import 'browser_wad_picker_stub.dart'
    if (dart.library.js_interop) 'browser_wad_picker_web.dart'
    as platform;
import 'browser_wad_selection.dart';

export 'browser_wad_selection.dart';

bool get browserWadPickerAvailable => platform.browserWadPickerAvailable;

Future<BrowserWadSelection?> pickBrowserWad() => platform.pickBrowserWad();
