from __future__ import annotations

import hashlib
from http.client import IncompleteRead
import io
from pathlib import Path
import sys
import tempfile
import unittest
from urllib.error import URLError
import zipfile


PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "tool"))

import fetch_shareware as fetch  # noqa: E402


def _fixture(payload: bytes) -> tuple[bytes, fetch.SharewareSpec]:
    inner_buffer = io.BytesIO()
    with zipfile.ZipFile(inner_buffer, "w", zipfile.ZIP_DEFLATED) as inner:
        inner.writestr("SETUP.EXE", b"authored fixture; never execute")
        inner.writestr("DOOM1.WAD", payload)
    split = b"MZ authored split archive prefix\0" + inner_buffer.getvalue()
    split_at = len(split) // 2
    parts = (split[:split_at], split[split_at:])
    outer_buffer = io.BytesIO()
    with zipfile.ZipFile(outer_buffer, "w", zipfile.ZIP_DEFLATED) as outer:
        outer.writestr("DEICE.EXE", b"authored fixture; never execute")
        outer.writestr("DOOMS_19.DAT", b"authored fixture metadata")
        outer.writestr("DOOMS_19.1", parts[0])
        outer.writestr("DOOMS_19.2", parts[1])
    archive = outer_buffer.getvalue()
    spec = fetch.SharewareSpec(
        url="https://example.invalid/doom19s.zip",
        archive_size=len(archive),
        archive_sha256=hashlib.sha256(archive).hexdigest(),
        part_sizes=(len(parts[0]), len(parts[1])),
        wad_size=len(payload),
        wad_sha256=hashlib.sha256(payload).hexdigest(),
    )
    return archive, spec


class _Response(io.BytesIO):
    status = 200

    def __init__(self, payload: bytes, url: str) -> None:
        super().__init__(payload)
        self.headers = {"Content-Length": str(len(payload))}
        self._url = url

    def geturl(self) -> str:
        return self._url

    def __enter__(self):
        return self

    def __exit__(self, *unused) -> None:
        self.close()


class FetchSharewareTest(unittest.TestCase):
    def test_official_source_and_output_identity_are_pinned(self) -> None:
        self.assertEqual(
            fetch.OFFICIAL_SPEC.url,
            "https://www.gamers.org/pub/idgames/idstuff/doom/doom19s.zip",
        )
        self.assertEqual(fetch.OFFICIAL_SPEC.archive_size, 2_450_688)
        self.assertEqual(
            fetch.OFFICIAL_SPEC.archive_sha256,
            "cacf0142b31ca1af00796b4a0339e07992ac5f21bc3f81e7532fe1b5e1b486e6",
        )
        self.assertEqual(fetch.OFFICIAL_SPEC.wad_size, 4_196_020)
        self.assertEqual(
            fetch.OFFICIAL_SPEC.wad_sha256,
            "1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771",
        )

    def test_extracts_only_authored_wad_member_from_split_sfx_zip(self) -> None:
        payload = b"authored non-commercial fixture bytes"
        archive, spec = _fixture(payload)
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            source = root / "source.zip"
            output = root / "DOOM1.WAD"
            source.write_bytes(archive)

            fetch._extract_wad(source, output, spec)

            self.assertEqual(output.read_bytes(), payload)
            self.assertFalse((root / "SETUP.EXE").exists())
            self.assertFalse((root / "DEICE.EXE").exists())

    def test_download_retries_transient_failure_and_validates_identity(self) -> None:
        payload = b"authored retry fixture"
        archive, spec = _fixture(payload)
        calls = []

        def opener(request, *, timeout):
            calls.append((request.full_url, timeout))
            if len(calls) < 3:
                raise URLError("authored transient failure")
            return _Response(archive, spec.url)

        with tempfile.TemporaryDirectory() as name:
            output = Path(name) / "source.zip"
            fetch._download_archive(
                output,
                spec,
                opener=opener,
                sleeper=lambda unused: None,
            )

            self.assertEqual(output.read_bytes(), archive)
        self.assertEqual(len(calls), 3)
        self.assertTrue(all(timeout == 30 for _, timeout in calls))

    def test_download_retries_interrupted_chunked_response(self) -> None:
        archive, spec = _fixture(b"authored interrupted response fixture")

        class InterruptedResponse(_Response):
            def read(self, size=-1):
                raise IncompleteRead(b"partial authored response")

        for succeeds in (True, False):
            with self.subTest(succeeds=succeeds), tempfile.TemporaryDirectory() as name:
                calls = []

                def opener(request, *, timeout):
                    calls.append(request.full_url)
                    response_type = _Response if succeeds and len(calls) == 3 else InterruptedResponse
                    return response_type(archive, spec.url)

                output = Path(name) / "source.zip"
                if succeeds:
                    fetch._download_archive(output, spec, opener=opener, sleeper=lambda _: None)
                    self.assertEqual(output.read_bytes(), archive)
                else:
                    with self.assertRaisesRegex(fetch.SharewareFetchError, "3 attempt.*IncompleteRead"):
                        fetch._download_archive(output, spec, opener=opener, sleeper=lambda _: None)
                self.assertEqual(len(calls), 3)

    def test_existing_valid_destination_is_fast_path(self) -> None:
        payload = b"authored existing fixture"
        _, spec = _fixture(payload)
        with tempfile.TemporaryDirectory() as name:
            destination = Path(name) / "DOOM1.WAD"
            destination.write_bytes(payload)

            def must_not_download(unused_path, unused_spec):
                self.fail("valid destination must not download")

            result = fetch.fetch_shareware(
                destination,
                spec=spec,
                downloader=must_not_download,
            )

            self.assertEqual(result, "existing")
            self.assertEqual(destination.read_bytes(), payload)

    def test_invalid_existing_destination_is_not_overwritten(self) -> None:
        payload = b"authored expected fixture"
        _, spec = _fixture(payload)
        existing = b"user file that must remain untouched"
        with tempfile.TemporaryDirectory() as name:
            destination = Path(name) / "DOOM1.WAD"
            destination.write_bytes(existing)

            with self.assertRaises(fetch.SharewareFetchError):
                fetch.fetch_shareware(
                    destination,
                    spec=spec,
                    downloader=lambda unused_path, unused_spec: self.fail(
                        "invalid existing destination must fail before download"
                    ),
                )

            self.assertEqual(destination.read_bytes(), existing)

    def test_authored_archive_installs_without_executing_members(self) -> None:
        payload = b"authored install fixture"
        archive, spec = _fixture(payload)

        def downloader(path: Path, unused_spec: fetch.SharewareSpec) -> None:
            path.write_bytes(archive)

        with tempfile.TemporaryDirectory() as name:
            destination = Path(name) / "nested" / "DOOM1.WAD"
            result = fetch.fetch_shareware(
                destination,
                spec=spec,
                downloader=downloader,
            )

            self.assertEqual(result, "installed")
            self.assertEqual(destination.read_bytes(), payload)
            self.assertEqual(
                list(destination.parent.glob("*.EXE")),
                [],
            )

    def test_rejects_wrong_final_wad_hash(self) -> None:
        payload = b"authored hash fixture"
        archive, spec = _fixture(payload)
        bad_spec = fetch.SharewareSpec(
            url=spec.url,
            archive_size=spec.archive_size,
            archive_sha256=spec.archive_sha256,
            part_sizes=spec.part_sizes,
            wad_size=spec.wad_size,
            wad_sha256="0" * 64,
        )
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            source = root / "source.zip"
            output = root / "DOOM1.WAD"
            source.write_bytes(archive)

            with self.assertRaises(fetch.SharewareFetchError):
                fetch._extract_wad(source, output, bad_spec)


if __name__ == "__main__":
    unittest.main()
