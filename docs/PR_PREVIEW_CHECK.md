# PR preview acceptance check

This documentation-only change exercises the production PR preview pipeline
without changing gameplay or the pinned engine stack.

1. The source PR workflow must finish its tests and Wasm build successfully.
2. The trusted publisher must validate this PR head and the source artifact.
3. The PR head must receive a successful `Cloudflare Pages preview` status.
4. The `github-actions[bot]` comment must link the immutable build and `pr-N` alias.
5. Both URLs must render the original E1M1 without an initial file chooser.
6. Verify Wasm MIME, COOP/COEP, and the bundled shareware SHA-256 as described
   in [PUBLISHING.md](PUBLISHING.md).

A successful upload alone does not complete this checklist. This file records
the acceptance procedure, not a claim that any particular deployment passed.
