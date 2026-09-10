import 'package:flutter/material.dart';

/// Render a usable shell before asynchronous WebGPU initialization begins.
final class DoomStartup extends StatefulWidget {
  const DoomStartup({super.key, required this.initialize, required this.child});
  final Future<void> Function() initialize;
  final Widget child;
  @override
  State<DoomStartup> createState() => _DoomStartupState();
}

final class _DoomStartupState extends State<DoomStartup> {
  bool _ready = false;
  bool _failed = false;
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      await widget.initialize();
      if (mounted) setState(() => _ready = true);
    } catch (error, stack) {
      debugPrint('Doom renderer initialization failed: $error\n$stack');
      if (mounted) setState(() => _failed = true);
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) => _ready
      ? widget.child
      : MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(),
          home: Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'DOOMPELLER',
                        style: TextStyle(
                          color: Color(0xFFC8B45A),
                          fontSize: 28,
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (_failed) ...[
                        const Text(
                          'Could not start the 3D graphics.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Use a browser with WebGPU support and check your connection, then try again.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        FilledButton(
                          key: const Key('retry-renderer'),
                          onPressed: _start,
                          child: const Text('TRY AGAIN'),
                        ),
                      ] else ...[
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        const Text('STARTING GRAPHICS'),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
}
