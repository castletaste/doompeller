import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;
import 'package:doom_wad/doom_wad.dart';

import 'browser_wad_selection.dart';

bool get browserWadPickerAvailable => true;

bool _pickerActive = false;

Future<BrowserWadSelection?> pickBrowserWad() async {
  if (_pickerActive) return null;
  _pickerActive = true;
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = '.wad,.WAD'
    ..multiple = false
    ..style.display = 'none';
  web.document.body?.append(input);

  final result = Completer<bool>();
  final StreamSubscription<web.Event> changed = web
      .EventStreamProviders
      .changeEvent
      .forTarget(input)
      .listen((_) {
        if (!result.isCompleted) result.complete(true);
      }, onError: result.completeError);
  final StreamSubscription<web.Event> cancelled = web
      .EventStreamProviders
      .cancelEvent
      .forTarget(input)
      .listen((_) {
        if (!result.isCompleted) result.complete(false);
      }, onError: result.completeError);

  try {
    // Called synchronously from a Flutter button, preserving the browser's
    // trusted user gesture for the native file chooser.
    input.click();
    if (!await result.future) {
      return null;
    }
    final web.File? file = input.files?.item(0);
    if (file == null) return null;
    if (file.size > DoomLimits.defaults.maxWadBytes) {
      throw const BrowserWadPickerFailure(
        'The selected IWAD exceeds the 256 MiB safety limit.',
      );
    }
    final JSArrayBuffer buffer;
    try {
      buffer = await file.arrayBuffer().toDart;
    } on Object {
      throw const BrowserWadPickerFailure(
        'The browser could not read the selected IWAD.',
      );
    }
    return BrowserWadSelection(
      name: file.name,
      bytes: buffer.toDart.asUint8List(),
    );
  } finally {
    await changed.cancel();
    await cancelled.cancel();
    input.remove();
    _pickerActive = false;
  }
}
