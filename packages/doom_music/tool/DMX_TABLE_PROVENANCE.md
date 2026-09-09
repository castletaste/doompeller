# DMX compatibility-table provenance

`lib/src/dmx_tables.dart` is behavioral data reconstructed without reading or
copying a DMX or Chocolate Doom table. Yamaha's YM3812 documentation defines
the register meanings, but not these sequencer curves.

The local oracle was Chocolate Doom commit
[`895f581c5d91497bdda0516612da803fe5843e28`](https://github.com/chocolate-doom/chocolate-doom/commit/895f581c5d91497bdda0516612da803fe5843e28),
configured for `opl_doom_1_9`, OPL2, 49,716 Hz and music volume 127. A generated
IWAD containing only an authored synthetic `GENMIDI` lump was paired with eight
authored MUS sweeps. No commercial WAD bytes or derived trace is stored in this
repository.

The frequency probes cover every note `0..127` and bend `-64..63`, yielding all
668 curve entries including repeated values and the final high-note anomaly.
The volume probes cover every channel volume `0..127` and every sounding note
velocity `1..127`, yielding 16,256 carrier attenuation observations. `V[0]` is
set to zero: zero and one are indistinguishable at the six-bit output level,
and zero preserves mute semantics.

Local reproducibility anchors from the approved disposable oracle:

- synthetic WAD SHA-256:
  `1f78a557f461fbc2a15f1f5eb673d750a7f238bcc305e4a87298dee655b8e88a`
- derived curve JSON SHA-256:
  `e1d0abaef5e5a361c2883dad1f2c9d7eea4834512b6259d1ba8a6f90f9af128d`
- frequency trace SHA-256 values:
  `7b0054265e053462bf6ecb27f256ea192e89bc398dc4a25e7a366975490b6bba`,
  `9a1b0b60ad87d0c33fe01b2b39476c63bf5fff8ec2c7372b815dd328f83b72b4`,
  `36710f02350c1eb68660c22c619e61f9cef5d4ea619211618cbe12578a4cb535`,
  `3a4a1712c00bff674cb590de81b465ffba91885534a745b92959a5530074c315`
- volume trace SHA-256 values:
  `d015302e0fad61366a50691f35d27b6d69f04f27f3e695378056288d8ab8ba44`,
  `f3000ca2315603d15270b9d5489b6f8b490ab97163df4558298cc7224f2bbbf5`,
  `f6b2eef8b4e2c66d5fd389ff0b561de98401339be933511de59f296d7d258862`,
  `964f00d5c5a59c9b46b8b6b98ecfe2685fcce454bd5075bb84c378a16b2b5194`

`register_trace.dart` emits the same timestamped register-trace contract for a
production frontend. It accepts either a WAD lump or a separate MUS file:

```sh
dart run tool/register_trace.dart \
  --wad /path/to/doom.wad --lump D_E1M1 \
  --frames 1491480 --output /tmp/D_E1M1.json
```

The production frontend was also compared over 300 seconds per track against
the same pinned oracle for the required `D_E1M1` through `D_E1M9`, `D_INTER`,
and `D_VICTOR`, plus `D_INTRO` as an extra. All 12 ordered register streams
were exact, and every horizon crossed at least one loop. The local summary
(which refers to untracked WAD-derived JSON) has SHA-256
`0ce90dfe59bdce44dd5de092a916826080b8d5a8a00faeccb761702d7ae54f24`.
