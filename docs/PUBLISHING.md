# Publishing Doompeller

## Targets

- Public source: https://github.com/castletaste/doompeller
- Production: https://doompeller.castletaste.dev
- Cloudflare Pages Direct Upload project: `castletaste-doompeller`
- Production branch: `main`
- PR branch alias: `https://pr-N.castletaste-doompeller.pages.dev`

GitHub Actions builds the static Flutter Wasm / Flame 3D WebGPU application.
There is no server-side Doom engine or Pages Function. The pinned game stack
remains Flutter 3.44.4, Flame 1.38.0, flame_3d 0.3.0 and naga-cli 30.0.1.
The published bootstrap has only `dart2wasm` / `skwasm`, no dart2js fallback.

## Content input

The approved CI source is the Doom Shareware 1.9 archive:
https://www.gamers.org/pub/idgames/idstuff/doom/doom19s.zip

`python3 tool/fetch_shareware.py` obtains only the required `DOOM1.WAD` from
the archive without running its installer. The outer archive is pinned to
2,450,688 bytes and SHA-256
`cacf0142b31ca1af00796b4a0339e07992ac5f21bc3f81e7532fe1b5e1b486e6`.
It verifies the final file:

- Bytes: `4196020`
- SHA-256: `1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771`

The file is cached by its content identity and reverified before use. It is
never added to Git. The approved web output includes it at
`assets/.local/doom/DOOM1.WAD`, so E1M1 starts automatically and the file picker
stays in the pause menu. This public delivery is intentional. Unexpected WAD
files and an incorrect copy at the approved path fail validation.

## Production and previews

`deploy-web.yml` verifies the source, tests the three pure-Dart packages and
Flutter app against the original E1 content, then builds and packages the
Wasm site. PR builds do not receive deployment credentials.

Only `main` may deploy production. The `production` GitHub environment uses
selected deployment branches with exactly `main`, not the broader protected-
branches option. Its `CLOUDFLARE_API_TOKEN` needs only Cloudflare Pages Edit in
the selected account. `CLOUDFLARE_ACCOUNT_ID` is a repository secret. Token
values must not enter source, logs, artifacts or PR code.

`deploy-pr-preview.yml` runs the trusted publisher from the default branch
after a successful PR build. It validates the source workflow, run, exact
artifact, open same-repository PR and current head. Fork previews are rejected.
The artifact is treated as untrusted data: only a bounded static site is
accepted, with no worker/function entrypoints, symlinks or executable build
configuration. The publisher never executes PR code with credentials.

Before deployment, the publisher rechecks the PR head. It deploys to `pr-N`,
publishes a status with the immutable deployment URL, and updates its own PR
comment with that URL and the branch alias. The alias is mutable; use the
immutable URL to identify a particular reviewed build. Previous previews are
not automatically deleted when a PR closes.

## Verification and failure behavior

Both production and previews must preserve COOP/COEP from `web/_headers`, serve
Wasm with its correct MIME type, include the exact approved WAD and contain no
dart2js fallback. Browser verification must observe E1M1 itself, not merely a
successful HTTP response or a Flutter loading screen.

An unavailable content mirror or wrong checksum fails the build. A failed or
stale PR build does not publish a new successful preview. DNS and TLS activation
may take longer than the upload; a successful Pages API call alone is not proof
that the custom hostname is ready. Existing gameplay and geometry limitations
remain documented in [VERIFICATION.md](VERIFICATION.md); deployment validation
does not imply a complete browser playthrough or a presented-frame 60 FPS claim.
