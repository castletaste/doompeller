import 'package:flutter/material.dart';

import '../game/audio_session.dart';

/// Session-only settings; changes rebuild this panel, not the game surface.
final class DoomAudioSettings extends StatelessWidget {
  const DoomAudioSettings({super.key, required this.session});

  final DoomAudioSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => Material(
      type: MaterialType.transparency,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Volume(
            label: 'MUSIC',
            sliderKey: const Key('pause-music-volume'),
            value: session.musicVolume,
            onChanged: session.setMusicVolume,
          ),
          _Volume(
            label: 'SOUND EFFECTS',
            sliderKey: const Key('pause-effects-volume'),
            value: session.effectsVolume,
            onChanged: session.setEffectsVolume,
          ),
          if (session.errorMessage case final String message)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                message,
                key: const Key('pause-audio-error'),
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
  );
}

final class _Volume extends StatelessWidget {
  const _Volume({
    required this.label,
    required this.sliderKey,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final Key sliderKey;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Column(
      children: [
        Row(
          children: [
            Text(label),
            const Spacer(),
            Text('${(value * 100).round()}%'),
          ],
        ),
        Semantics(
          label: label,
          child: Slider(
            key: sliderKey,
            value: value,
            label: '${(value * 100).round()}%',
            onChanged: onChanged,
          ),
        ),
      ],
    ),
  );
}
