#!/usr/bin/env python3
"""Fetch and validate the Doom 1.9 shareware IWAD without running installers."""

from __future__ import annotations

import argparse
import hashlib
from http.client import IncompleteRead
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time
from dataclasses import dataclass
from typing import Callable, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
import zipfile


@dataclass(frozen=True)
class SharewareSpec:
    url: str
    archive_size: int
    archive_sha256: str
    part_sizes: tuple[int, int]
    wad_size: int
    wad_sha256: str


OFFICIAL_SPEC = SharewareSpec(
    url="https://www.gamers.org/pub/idgames/idstuff/doom/doom19s.zip",
    archive_size=2_450_688,
    archive_sha256="cacf0142b31ca1af00796b4a0339e07992ac5f21bc3f81e7532fe1b5e1b486e6",
    part_sizes=(1_439_232, 994_588),
    wad_size=4_196_020,
    wad_sha256="1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771",
)

_PART_NAMES = ("DOOMS_19.1", "DOOMS_19.2")
_WAD_MEMBER = "DOOM1.WAD"
_CHUNK_SIZE = 64 * 1024
_DOWNLOAD_ATTEMPTS = 3
_DOWNLOAD_TIMEOUT_SECONDS = 30


class SharewareFetchError(RuntimeError):
    """A fail-closed source, archive, or destination validation failure."""


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(_CHUNK_SIZE), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _identity(path: Path) -> tuple[int, str]:
    return path.stat().st_size, _sha256(path)


def _matches(path: Path, expected_size: int, expected_sha256: str) -> bool:
    try:
        size, digest = _identity(path)
    except (FileNotFoundError, OSError):
        return False
    return size == expected_size and digest == expected_sha256


def _validate_archive(path: Path, spec: SharewareSpec) -> None:
    if not _matches(path, spec.archive_size, spec.archive_sha256):
        raise SharewareFetchError(
            "downloaded shareware archive failed exact size/SHA-256 validation"
        )


def _download_archive(
    destination: Path,
    spec: SharewareSpec,
    *,
    opener: Callable[..., object] = urlopen,
    sleeper: Callable[[float], None] = time.sleep,
    attempts: int = _DOWNLOAD_ATTEMPTS,
    timeout: int = _DOWNLOAD_TIMEOUT_SECONDS,
) -> None:
    if attempts < 1:
        raise ValueError("attempts must be positive")
    request = Request(
        spec.url,
        headers={"User-Agent": "Doompeller-shareware-fetch/1"},
    )
    last_error: Optional[BaseException] = None
    for attempt in range(1, attempts + 1):
        try:
            with opener(request, timeout=timeout) as response:  # type: ignore[attr-defined]
                status = getattr(response, "status", 200)
                if status != 200:
                    raise SharewareFetchError(
                        f"shareware download returned HTTP {status}"
                    )
                final_url = getattr(response, "geturl", lambda: spec.url)()
                if urlsplit(final_url).scheme != "https":
                    raise SharewareFetchError(
                        "shareware download redirected away from HTTPS"
                    )
                content_length = getattr(response, "headers", {}).get(
                    "Content-Length"
                )
                if content_length is not None:
                    try:
                        reported_size = int(content_length)
                    except ValueError as error:
                        raise SharewareFetchError(
                            "shareware server returned an invalid archive size"
                        ) from error
                    if reported_size != spec.archive_size:
                        raise SharewareFetchError(
                            "shareware server returned an unexpected archive size"
                        )
                total = 0
                with destination.open("wb") as output:
                    while True:
                        chunk = response.read(_CHUNK_SIZE)
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > spec.archive_size:
                            raise SharewareFetchError(
                                "shareware download exceeded the pinned archive size"
                            )
                        output.write(chunk)
            _validate_archive(destination, spec)
            return
        except SharewareFetchError as error:
            last_error = error
        except HTTPError as error:
            last_error = error
            if error.code not in (408, 429) and error.code < 500:
                break
        except (URLError, TimeoutError, OSError, IncompleteRead) as error:
            last_error = error
        if attempt < attempts:
            sleeper(float(2 ** (attempt - 1)))
    if isinstance(last_error, SharewareFetchError):
        detail = str(last_error)
    else:
        detail = type(last_error).__name__ if last_error is not None else "error"
    raise SharewareFetchError(
        f"shareware download failed after {attempt} attempt(s) ({detail})"
    ) from last_error


def _unique_member(archive: zipfile.ZipFile, name: str) -> zipfile.ZipInfo:
    matches = [entry for entry in archive.infolist() if entry.filename == name]
    if len(matches) != 1:
        raise SharewareFetchError(
            f"shareware archive must contain exactly one {name} member"
        )
    entry = matches[0]
    if entry.is_dir():
        raise SharewareFetchError(f"shareware archive member {name} is a directory")
    return entry


def _copy_exact_member(
    archive: zipfile.ZipFile,
    entry: zipfile.ZipInfo,
    output,
    expected_size: int,
) -> None:
    if entry.file_size != expected_size:
        raise SharewareFetchError(
            f"shareware member {entry.filename} has an unexpected size"
        )
    total = 0
    with archive.open(entry, "r") as source:
        while True:
            chunk = source.read(min(_CHUNK_SIZE, expected_size + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > expected_size:
                raise SharewareFetchError(
                    f"shareware member {entry.filename} exceeded its pinned size"
                )
            output.write(chunk)
    if total != expected_size:
        raise SharewareFetchError(
            f"shareware member {entry.filename} was truncated"
        )


def _extract_wad(
    archive_path: Path,
    candidate_path: Path,
    spec: SharewareSpec,
) -> None:
    """Read the split SFX ZIP as data and extract only its DOOM1.WAD member."""
    _validate_archive(archive_path, spec)
    split_payload = candidate_path.with_name("dooms_19_split_payload.bin")
    try:
        with zipfile.ZipFile(archive_path, "r") as outer:
            entries = [
                _unique_member(outer, name) for name in _PART_NAMES
            ]
            with split_payload.open("xb") as combined:
                for entry, expected_size in zip(entries, spec.part_sizes):
                    _copy_exact_member(outer, entry, combined, expected_size)

        if split_payload.stat().st_size != sum(spec.part_sizes):
            raise SharewareFetchError("split shareware payload has an unexpected size")

        with zipfile.ZipFile(split_payload, "r") as inner:
            wad_entry = _unique_member(inner, _WAD_MEMBER)
            with candidate_path.open("xb") as candidate:
                _copy_exact_member(inner, wad_entry, candidate, spec.wad_size)
        if not _matches(candidate_path, spec.wad_size, spec.wad_sha256):
            raise SharewareFetchError(
                "extracted DOOM1.WAD failed exact size/SHA-256 validation"
            )
    except SharewareFetchError:
        raise
    except (OSError, RuntimeError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        raise SharewareFetchError("could not parse the shareware split archives") from error


def _validate_existing_destination(destination: Path, spec: SharewareSpec) -> bool:
    if destination.is_symlink():
        raise SharewareFetchError(
            f"destination is a symlink; refusing to use or replace it: {destination}"
        )
    if not os.path.lexists(destination):
        return False
    if not destination.is_file() or not _matches(
        destination, spec.wad_size, spec.wad_sha256
    ):
        raise SharewareFetchError(
            f"existing destination is not the pinned DOOM1.WAD; refusing to overwrite: {destination}"
        )
    return True


def _install_without_overwrite(
    candidate: Path,
    destination: Path,
    spec: SharewareSpec,
) -> str:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary_name: Optional[str] = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=f".{destination.name}.",
            suffix=".tmp",
            dir=destination.parent,
            delete=False,
        ) as temporary:
            temporary_name = temporary.name
            with candidate.open("rb") as source:
                shutil.copyfileobj(source, temporary, length=_CHUNK_SIZE)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_name, 0o644)
        try:
            os.link(temporary_name, destination)
            return "installed"
        except FileExistsError:
            if _validate_existing_destination(destination, spec):
                return "existing"
            raise
    finally:
        if temporary_name is not None:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def fetch_shareware(
    destination: Path,
    *,
    spec: SharewareSpec = OFFICIAL_SPEC,
    downloader: Callable[[Path, SharewareSpec], None] = _download_archive,
) -> str:
    if _validate_existing_destination(destination, spec):
        return "existing"
    with tempfile.TemporaryDirectory(prefix="doompeller-shareware-") as name:
        workspace = Path(name)
        archive_path = workspace / "doom19s.zip"
        candidate_path = workspace / _WAD_MEMBER
        downloader(archive_path, spec)
        _extract_wad(archive_path, candidate_path, spec)
        # A concurrent creator must be validated, never overwritten.
        if _validate_existing_destination(destination, spec):
            return "existing"
        return _install_without_overwrite(candidate_path, destination, spec)


def verify_download(spec: SharewareSpec = OFFICIAL_SPEC) -> None:
    with tempfile.TemporaryDirectory(prefix="doompeller-shareware-verify-") as name:
        workspace = Path(name)
        archive_path = workspace / "doom19s.zip"
        candidate_path = workspace / _WAD_MEMBER
        _download_archive(archive_path, spec)
        _extract_wad(archive_path, candidate_path, spec)


def _default_destination() -> Path:
    return Path(__file__).resolve().parent.parent / ".local" / "doom" / _WAD_MEMBER


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Fetch and verify the official Doom 1.9 shareware IWAD."
    )
    parser.add_argument(
        "destination",
        nargs="?",
        type=Path,
        default=_default_destination(),
        help="destination path (default: repository .local/doom/DOOM1.WAD)",
    )
    parser.add_argument(
        "--verify-download",
        action="store_true",
        help="download and validate in temporary storage without installing",
    )
    args = parser.parse_args(argv)
    try:
        if args.verify_download:
            verify_download()
            print("validated official Doom 1.9 shareware download")
            return 0
        outcome = fetch_shareware(args.destination)
        print(f"{outcome} validated DOOM1.WAD: {args.destination}")
        return 0
    except SharewareFetchError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(
            f"error: local filesystem operation failed ({type(error).__name__})",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
