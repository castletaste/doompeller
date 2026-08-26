# Duplicate-preserving texture directory

Found while auditing animated textures against a real IWAD's structure. Not a
stock-E1M1 blocker, and deliberately deferred: the fix changes `doom_wad`'s
public shape, so it needs its own approved scope.

## What vanilla does

`R_InitTextures` concatenates TEXTURE1 and TEXTURE2 into one numbered
directory and keeps every entry, including two entries that share a name.
`R_TextureNumForName` then scans from the start, so a name resolves to the
first definition. Animation ranges are resolved by *number*, not by name:
`P_InitPicAnims` walks from the start frame's index to the end frame's index.

## What we do now

We resolve names first-wins, which is correct, but we also deduplicate the
catalogue. A duplicate name therefore disappears from the numbering.

With `TEXTURE1 = [START, MID]` and `TEXTURE2 = [MID, END]`, vanilla animates
four frames and we animate three. The cycle runs short.

## Why the small fix is wrong

Simply letting duplicates back into the name list restores the frame count but
not the meaning: two entries named `MID` can hold different patches, so the
atlas would key one image under a name that also refers to another.

The honest fix is a numbered directory that preserves duplicates, with lookup
by index and stable texture handles carried through geometry and atlas
identity. That touches the `doom_wad` API, the compiler, and atlas keying.

## Impact

Stock `DOOM.WAD` is not known to ship duplicate texture names, so this is a
correctness gap against PWADs rather than a first-run risk. Revisit if a real
IWAD or PWAD ever animates a short cycle.
