import 'package:doom_core/doom_core.dart' as core;
import 'package:flutter/material.dart';
import '../game/doom_hud.dart';

final class DoomStatusBar extends StatelessWidget {
  const DoomStatusBar({super.key, required this.hud, required this.synthetic});

  final DoomHudSnapshot hud;
  final bool synthetic;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final bool narrow = constraints.maxWidth < 520;
      final items = <Widget>[
        _StatusValue(label: 'AMMO', value: _ammo(hud)),
        _StatusValue(label: 'HEALTH', value: '${hud.health}%'),
        _StatusValue(label: 'ARMOR', value: '${hud.armor}%'),
        _StatusValue(label: 'WEAPON', value: hud.weapon.name.toUpperCase()),
        _StatusValue(label: 'KEYS', value: _keys(hud.keys)),
        _StatusValue(label: 'SECRET', value: '${hud.secrets}'),
      ];
      return Container(
        key: const Key('status-bar'),
        color: const Color(0xEE171512),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: narrow
            ? Wrap(
                alignment: WrapAlignment.spaceBetween,
                runSpacing: 5,
                children: <Widget>[
                  for (final item in items)
                    SizedBox(width: constraints.maxWidth / 3 - 9, child: item),
                ],
              )
            : Row(
                children: <Widget>[
                  for (final item in items) Expanded(child: item),
                  Text(
                    synthetic ? 'TEST' : 'IWAD',
                    style: TextStyle(
                      color: synthetic
                          ? const Color(0xFFE0B64D)
                          : const Color(0xFF61B879),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
      );
    },
  );

  static String _ammo(DoomHudSnapshot hud) => switch (hud.weapon) {
    core.Weapon.shotgun => '${hud.shells}',
    core.Weapon.fist || core.Weapon.chainsaw => '—',
    core.Weapon.rocketLauncher => '${hud.rockets}',
    core.Weapon.pistol || core.Weapon.chaingun => '${hud.bullets}',
  };

  static String _keys(Set<core.Key> keys) => <String>[
    if (keys.contains(core.Key.blue)) 'B',
    if (keys.contains(core.Key.yellow)) 'Y',
    if (keys.contains(core.Key.red)) 'R',
  ].join().padRight(3, '·');
}

final class _StatusValue extends StatelessWidget {
  const _StatusValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Text(
        label,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white54, fontSize: 9),
      ),
      Text(
        value,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
      ),
    ],
  );
}
