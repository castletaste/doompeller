#!/usr/bin/env python3
"""Pack and verify the static web artifact passed between CI jobs."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import tarfile
import tempfile


EXPECTED_WAD_PATH = PurePosixPath("assets/.local/doom/DOOM1.WAD")
EXPECTED_WAD_BYTES = 4_196_020
EXPECTED_WAD_SHA256 = (
    "1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771"
)
TRUSTED_HEADERS_PATH = Path(__file__).resolve().parent.parent / "web" / "_headers"
MAX_FILES = 20_000
MAX_FILE_BYTES = 25 * 1024 * 1024
MAX_TOTAL_BYTES = 256 * 1024 * 1024

ALLOWED_ROOT_FILES = {
    "_headers",
    "favicon.png",
    "flutter.js",
    "flutter_bootstrap.js",
    "flutter_service_worker.js",
    "index.html",
    "main.dart.mjs",
    "main.dart.wasm",
    "doom_music_worker.wasm",
    "doom_music_worker.mjs",
    "doom_music_worker_loader.mjs",
    "doom_music_worklet.js",
    "manifest.json",
    "version.json",
}
ALLOWED_ROOT_DIRECTORIES = {"assets", "canvaskit", "icons"}
REQUIRED_FILES = {
    PurePosixPath("_headers"),
    PurePosixPath("flutter_bootstrap.js"),
    PurePosixPath("index.html"),
    PurePosixPath("main.dart.mjs"),
    PurePosixPath("main.dart.wasm"),
    PurePosixPath("doom_music_worker.wasm"),
    PurePosixPath("doom_music_worker.mjs"),
    PurePosixPath("doom_music_worker_loader.mjs"),
    PurePosixPath("doom_music_worklet.js"),
    PurePosixPath("assets/assets/shaders/doom_palette.wgslbundle"),
    EXPECTED_WAD_PATH,
}
FORBIDDEN_NAMES = {
    "_routes.json",
    "_worker.js",
    "_worker.js.map",
    "bun.lock",
    "bun.lockb",
    "functions",
    "package-lock.json",
    "package.json",
    "pnpm-lock.yaml",
    "wrangler.json",
    "wrangler.jsonc",
    "wrangler.toml",
    "yarn.lock",
}


class ArtifactError(RuntimeError):
    pass


def _fail(message: str) -> None:
    raise ArtifactError(message)


def _validate_relative_path(
    relative: PurePosixPath, *, directory: bool = False
) -> None:
    if relative.is_absolute() or not relative.parts:
        _fail(f"unsafe artifact path: {relative}")
    if relative.parts[0] in ("", ".", "..") or ".." in relative.parts:
        _fail(f"unsafe artifact path: {relative}")
    if len(relative.as_posix()) > 1024:
        _fail(f"artifact path is too long: {relative}")

    for index, segment in enumerate(relative.parts):
        lower = segment.lower()
        if (
            not segment
            or len(segment) > 255
            or any(ord(character) < 32 or ord(character) == 127 for character in segment)
            or lower in FORBIDDEN_NAMES
            or lower.startswith("wrangler.")
        ):
            _fail(f"unsafe artifact path segment: {segment!r}")
        if segment.startswith("."):
            expected_parts = EXPECTED_WAD_PATH.parts
            allowed_local = index == 1 and segment == ".local" and (
                relative == EXPECTED_WAD_PATH
                or (
                    directory
                    and relative.parts == expected_parts[: len(relative.parts)]
                )
            )
            if not allowed_local:
                _fail(f"unexpected hidden artifact path: {relative}")

    root = relative.parts[0]
    if len(relative.parts) == 1:
        allowed = ALLOWED_ROOT_DIRECTORIES if directory else ALLOWED_ROOT_FILES
        if root not in allowed:
            kind = "directory" if directory else "file"
            _fail(f"unexpected artifact root {kind}: {root}")
    elif root not in ALLOWED_ROOT_DIRECTORIES:
        _fail(f"unexpected artifact root directory: {root}")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _validate_bundle(directory: Path) -> list[tuple[PurePosixPath, Path]]:
    if not directory.is_dir() or directory.is_symlink():
        _fail("web bundle must be a real directory")

    files: list[tuple[PurePosixPath, Path]] = []
    total_bytes = 0
    for root, directories, names in os.walk(directory, followlinks=False):
        root_path = Path(root)
        directories.sort()
        names.sort()
        for name in list(directories):
            child = root_path / name
            relative = PurePosixPath(child.relative_to(directory).as_posix())
            _validate_relative_path(relative, directory=True)
            if child.is_symlink():
                _fail(f"artifact contains symlink: {relative}")
        for name in names:
            path = root_path / name
            relative = PurePosixPath(path.relative_to(directory).as_posix())
            # Flutter's local incremental-build marker is not a deployable asset.
            if relative == PurePosixPath(".last_build_id"):
                continue
            _validate_relative_path(relative)
            file_stat = path.lstat()
            if not stat.S_ISREG(file_stat.st_mode):
                _fail(f"artifact contains a non-regular file: {relative}")
            if file_stat.st_size <= 0:
                _fail(f"artifact contains an empty file: {relative}")
            if file_stat.st_size > MAX_FILE_BYTES:
                _fail(f"artifact file exceeds size limit: {relative}")
            total_bytes += file_stat.st_size
            if total_bytes > MAX_TOTAL_BYTES:
                _fail("artifact exceeds total size limit")
            files.append((relative, path))
            if len(files) > MAX_FILES:
                _fail("artifact exceeds file count limit")

    present = {relative for relative, _ in files}
    missing = sorted(REQUIRED_FILES - present, key=str)
    if missing:
        _fail(f"artifact is missing required files: {', '.join(map(str, missing))}")
    if PurePosixPath("main.dart.js") in present:
        _fail("dart2js fallback must not be deployed")

    wad_files = [
        relative
        for relative in present
        if relative.suffix.lower() in {".wad", ".iwad", ".pwad"}
    ]
    if wad_files != [EXPECTED_WAD_PATH]:
        _fail("artifact must contain exactly the approved shareware IWAD")
    wad_path = directory / Path(*EXPECTED_WAD_PATH.parts)
    if wad_path.stat().st_size != EXPECTED_WAD_BYTES:
        _fail("bundled IWAD has the wrong size")
    if _sha256(wad_path) != EXPECTED_WAD_SHA256:
        _fail("bundled IWAD has the wrong SHA-256")

    # This script is checked out from the trusted source in the deploy job.
    # Exact normalized text also rejects appended rules that override isolation.
    expected_headers = TRUSTED_HEADERS_PATH.read_text(encoding="utf-8").strip()
    actual_headers = (directory / "_headers").read_text(encoding="utf-8").strip()
    if actual_headers != expected_headers:
        _fail("artifact _headers does not match the trusted header contract")

    bootstrap = (directory / "flutter_bootstrap.js").read_text(encoding="utf-8")
    if '"compileTarget":"dart2wasm"' not in bootstrap:
        _fail("Flutter bootstrap has no dart2wasm target")
    if '"renderer":"skwasm"' not in bootstrap:
        _fail("Flutter bootstrap does not select skwasm")
    if '"compileTarget":"dart2js"' in bootstrap:
        _fail("Flutter bootstrap still contains a dart2js target")
    if '"useLocalCanvasKit":true' not in bootstrap:
        _fail("Flutter bootstrap still uses an external renderer CDN")
    return sorted(files, key=lambda item: item[0].as_posix())


def pack(source: Path, archive: Path) -> None:
    files = _validate_bundle(source.resolve())
    archive = archive.resolve()
    archive.parent.mkdir(parents=True, exist_ok=True)
    if archive.exists():
        _fail(f"archive already exists: {archive}")
    with archive.open("xb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as output:
                for relative, path in files:
                    info = tarfile.TarInfo(relative.as_posix())
                    info.size = path.stat().st_size
                    info.mode = 0o644
                    info.mtime = 0
                    info.uid = 0
                    info.gid = 0
                    info.uname = ""
                    info.gname = ""
                    with path.open("rb") as contents:
                        output.addfile(info, contents)
    print(f"Packed {len(files)} verified web files into {archive}")


def extract(archive: Path, destination: Path) -> None:
    archive = archive.resolve()
    destination = destination.resolve()
    if destination.exists():
        _fail(f"destination already exists: {destination}")
    destination.mkdir(parents=True)
    seen: set[PurePosixPath] = set()
    total_bytes = 0
    try:
        with tarfile.open(archive, mode="r:gz") as source:
            for member in source:
                relative = PurePosixPath(member.name)
                _validate_relative_path(relative)
                if relative in seen:
                    _fail(f"duplicate archive entry: {relative}")
                seen.add(relative)
                if not member.isfile():
                    _fail(f"archive entry is not a regular file: {relative}")
                if member.size <= 0 or member.size > MAX_FILE_BYTES:
                    _fail(f"archive entry has invalid size: {relative}")
                total_bytes += member.size
                if total_bytes > MAX_TOTAL_BYTES or len(seen) > MAX_FILES:
                    _fail("archive exceeds bounded extraction limits")
                target = destination.joinpath(*relative.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                contents = source.extractfile(member)
                if contents is None:
                    _fail(f"could not read archive entry: {relative}")
                with target.open("xb") as output:
                    shutil.copyfileobj(contents, output)
        _validate_bundle(destination)
    except BaseException:
        shutil.rmtree(destination, ignore_errors=True)
        raise
    print(f"Extracted and verified {len(seen)} web files into {destination}")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    pack_parser = subparsers.add_parser("pack")
    pack_parser.add_argument("source", type=Path)
    pack_parser.add_argument("archive", type=Path)
    extract_parser = subparsers.add_parser("extract")
    extract_parser.add_argument("archive", type=Path)
    extract_parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "pack":
            pack(args.source, args.archive)
        else:
            extract(args.archive, args.destination)
    except (ArtifactError, OSError, tarfile.TarError, UnicodeError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
