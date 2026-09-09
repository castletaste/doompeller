import 'package:doom_core/doom_core.dart' as core;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../game/doom_hud.dart';

final class DoomIntermissionOverlay extends StatefulWidget {
  const DoomIntermissionOverlay({
    super.key,
    required this.hud,
    required this.onRestart,
    required this.onContinue,
    required this.nextMap,
    required this.episodeComplete,
    required this.advancing,
    this.errorMessage,
  });

  final DoomHudSnapshot hud;
  final VoidCallback onRestart;
  final VoidCallback onContinue;
  final String? nextMap;
  final bool episodeComplete;
  final bool advancing;
  final String? errorMessage;

  @override
  State<DoomIntermissionOverlay> createState() =>
      _DoomIntermissionOverlayState();
}

final class _DoomIntermissionOverlayState extends State<DoomIntermissionOverlay>
    with SingleTickerProviderStateMixin {
  final FocusNode _focusNode = FocusNode(debugLabel: 'Intermission tally');
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..forward();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _finishTally() {
    if (_controller.value < 1) _controller.value = 1;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    autofocus: true,
    onKeyEvent: (_, KeyEvent event) {
      if (event is KeyDownEvent) {
        if (_controller.isCompleted &&
            widget.nextMap != null &&
            !widget.advancing &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onContinue();
        } else {
          _finishTally();
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: GestureDetector(
      key: const Key('intermission-skip'),
      behavior: HitTestBehavior.opaque,
      onTap: _finishTally,
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.9),
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final double progress = _controller.value;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    widget.episodeComplete
                        ? 'EPISODE COMPLETE'
                        : 'LEVEL COMPLETE',
                    style: const TextStyle(
                      color: Color(0xFFC8B45A),
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _TallyRow(
                    label: 'KILLS',
                    value: _animatedPercent(
                      widget.hud.kills,
                      widget.hud.totalKills,
                      progress,
                      const Interval(0, 0.35),
                    ),
                  ),
                  _TallyRow(
                    label: 'ITEMS',
                    value: _animatedPercent(
                      widget.hud.items,
                      widget.hud.totalItems,
                      progress,
                      const Interval(0.25, 0.6),
                    ),
                  ),
                  _TallyRow(
                    label: 'SECRETS',
                    value: _animatedPercent(
                      widget.hud.secrets,
                      widget.hud.totalSecrets,
                      progress,
                      const Interval(0.5, 0.85),
                    ),
                  ),
                  _TallyRow(
                    label: 'TIME',
                    value: _animatedTime(
                      widget.hud.levelTime,
                      progress,
                      const Interval(0.75, 1),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'CLICK OR PRESS ANY KEY TO FINISH TALLY',
                    style: TextStyle(color: Colors.white54, fontSize: 10),
                  ),
                  const SizedBox(height: 16),
                  if (widget.errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 8,
                      ),
                      child: Text(
                        widget.errorMessage!,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (widget.nextMap != null)
                    FilledButton(
                      key: const Key('intermission-continue'),
                      onPressed: widget.advancing ? null : widget.onContinue,
                      child: Text(
                        widget.advancing
                            ? 'LOADING…'
                            : 'CONTINUE TO ${widget.nextMap}',
                      ),
                    ),
                  FilledButton.tonal(
                    key: const Key('intermission-restart'),
                    onPressed: widget.advancing ? null : widget.onRestart,
                    child: const Text('RESTART LEVEL'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  static String _animatedPercent(
    int count,
    int total,
    double progress,
    Interval interval,
  ) {
    final int target = total == 0
        ? 100
        : ((count * 100) ~/ total).clamp(0, 100);
    final double rowProgress = interval.transform(progress);
    return '${(target * rowProgress).round()}%';
  }

  static String _animatedTime(
    int levelTime,
    double progress,
    Interval interval,
  ) {
    final int seconds = levelTime ~/ core.kTicRate;
    final int shown = (seconds * interval.transform(progress)).round();
    final int minutes = shown ~/ 60;
    final int remainder = shown % 60;
    return '$minutes:${remainder.toString().padLeft(2, '0')}';
  }
}

final class _TallyRow extends StatelessWidget {
  const _TallyRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 260,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 18),
          ),
          Text(
            value,
            key: Key('tally-${label.toLowerCase()}'),
            style: const TextStyle(
              color: Color(0xFFC8B45A),
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    ),
  );
}
