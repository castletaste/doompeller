---
name: doompeller-content-license
description: "Handle Doom content and licensing boundaries in Doompeller: the developer-only local IWAD path, gitignore and artifact hygiene, synthetic fixture content, and the no-embedded-engine rule. Use before touching WAD files, assets, test corpora, or anything shipped."
---

# Doompeller Content and Licensing

Original Doom content is not public domain. This skill exists so a convenience shortcut never becomes a licensing incident.

- The user's own legally obtained copy lives at `.local/doom/DOOM.WAD`, read via the `DOOM_WAD_PATH` environment variable. Keep `.local/` and the WAD extension rules in `.gitignore` intact.
- The WAD and anything extracted from it — textures, sprites, sounds, palettes, maps, dumps, fixtures, screenshots used as test data — never reaches a commit, git history, a build artifact, or a release. Check `git status` for stray extracted data before committing, not just for source files.
- Never download or otherwise obtain a WAD automatically. If one is needed and absent, stop and ask the user for the path to their copy.
- Tests run against the generated `DoomFixtures` PWAD and must pass with no IWAD present. A test that silently skips when the IWAD is missing is a hole: make the skip explicit and reported.
- No Doom C source is embedded, translated verbatim, or wrapped, and the software renderer is not reused. Where a constant came from documentation rather than derivation, say so in a comment.
- Keep user-visible naming clear of implied endorsement. Public demo content and a WAD import UI are out of scope; adding either needs approval.

If a change would put commercial-derived bytes anywhere durable, stop and raise it rather than working around it.
