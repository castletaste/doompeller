import 'package:flutter/material.dart';

final class DoomLoadingView extends StatelessWidget {
  const DoomLoadingView({super.key});

  @override
  Widget build(BuildContext context) => const Center(
    child: Column(
      key: Key('loading-view'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox.square(dimension: 28, child: CircularProgressIndicator()),
        SizedBox(height: 16),
        Text('LOADING LEVEL'),
      ],
    ),
  );
}

final class DoomFailureView extends StatelessWidget {
  const DoomFailureView({
    super.key,
    required this.message,
    required this.onFallback,
  });

  final String message;
  final VoidCallback onFallback;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            key: const Key('failure-view'),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                'IWAD LOAD FAILED',
                style: TextStyle(
                  color: Color(0xFFFF6B5F),
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 18),
              FilledButton.tonal(
                key: const Key('fixture-fallback'),
                onPressed: onFallback,
                child: const Text('RUN SYNTHETIC TEST MAP'),
              ),
              const SizedBox(height: 10),
              const Text(
                'No content is substituted until you choose this fallback.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

final class DoomRuntimeConfigurationError extends StatelessWidget {
  const DoomRuntimeConfigurationError({
    super.key,
    this.message = 'The configured game runtime cannot be rendered.',
  });

  final String message;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const Key('runtime-configuration-error'),
    color: Colors.black,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message, textAlign: TextAlign.center),
      ),
    ),
  );
}

final class DoomPauseButton extends StatelessWidget {
  const DoomPauseButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('game-pause-button'),
    tooltip: 'Pause game',
    constraints: const BoxConstraints.tightFor(width: 36, height: 34),
    padding: EdgeInsets.zero,
    color: Colors.white70,
    onPressed: onPressed,
    icon: const Icon(Icons.pause, size: 18, semanticLabel: 'Pause game'),
  );
}

final class DoomContentBadge extends StatelessWidget {
  const DoomContentBadge({
    super.key,
    required this.synthetic,
    required this.mapName,
    this.setupMessage,
  });

  final bool synthetic;
  final String mapName;
  final String? setupMessage;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('content-badge'),
    constraints: const BoxConstraints(maxWidth: 430),
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.78),
      border: Border.all(
        color: synthetic ? const Color(0xFFE0B64D) : const Color(0xFF61B879),
      ),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          synthetic ? 'SYNTHETIC TEST MAP' : 'DEVELOPER IWAD · $mapName',
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
        ),
        if (synthetic && setupMessage != null)
          Text(
            setupMessage!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 10),
          ),
      ],
    ),
  );
}

final class DoomPauseOverlay extends StatelessWidget {
  const DoomPauseOverlay({
    super.key,
    required this.onResume,
    this.onLoadIwad,
    this.errorMessage,
  });

  final VoidCallback onResume;
  final VoidCallback? onLoadIwad;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black.withValues(alpha: 0.78),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text(
            'PAUSED',
            style: TextStyle(
              color: Color(0xFFC8B45A),
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Press Esc to resume',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            key: const Key('overlay-action'),
            onPressed: onResume,
            child: const Text('RESUME'),
          ),
          if (onLoadIwad != null) ...<Widget>[
            const SizedBox(height: 10),
            OutlinedButton(
              key: const Key('pause-load-iwad'),
              onPressed: onLoadIwad,
              child: const Text('SELECT LOCAL IWAD'),
            ),
          ],
          if (errorMessage != null) ...<Widget>[
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Text(
                errorMessage!,
                key: const Key('pause-iwad-error'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFFF6B5F)),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

final class DoomControlsHint extends StatelessWidget {
  const DoomControlsHint({
    super.key,
    required this.narrow,
    required this.onHide,
  });

  final bool narrow;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('controls-hint'),
    padding: const EdgeInsets.only(left: 9),
    color: Colors.black.withValues(alpha: 0.72),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          narrow
              ? 'WASD · SHIFT run · ←→ · CTRL · E'
              : 'W/S move · A/D strafe · Shift run · ←/→ turn · Ctrl/click fire · Space/E use · 1–6 weapon · Esc pause',
          style: const TextStyle(color: Colors.white70, fontSize: 10),
        ),
        IconButton(
          key: const Key('hide-controls'),
          tooltip: 'Hide controls',
          constraints: const BoxConstraints.tightFor(width: 32, height: 30),
          padding: EdgeInsets.zero,
          onPressed: onHide,
          icon: const Icon(Icons.close, size: 14),
        ),
      ],
    ),
  );
}

final class DoomModalOverlay extends StatelessWidget {
  const DoomModalOverlay({
    super.key,
    required this.title,
    required this.subtitle,
    this.onPressed,
    this.buttonLabel,
  });

  final String title;
  final String subtitle;
  final VoidCallback? onPressed;
  final String? buttonLabel;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black.withValues(alpha: 0.78),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFFC8B45A),
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(subtitle, style: const TextStyle(color: Colors.white70)),
          if (onPressed != null) ...<Widget>[
            const SizedBox(height: 16),
            FilledButton.tonal(
              key: const Key('overlay-action'),
              onPressed: onPressed,
              child: Text(buttonLabel ?? 'CONTINUE'),
            ),
          ],
        ],
      ),
    ),
  );
}
