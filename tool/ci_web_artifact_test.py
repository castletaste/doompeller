from __future__ import annotations

import io
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest

from ci_web_artifact import ArtifactError, TRUSTED_HEADERS_PATH, extract, pack


class CiWebArtifactTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def _bundle(self) -> Path:
        bundle = self.root / "web"
        files = {
            "_headers": TRUSTED_HEADERS_PATH.read_text(encoding="utf-8"),
            "flutter_bootstrap.js": (
                '{"compileTarget":"dart2wasm","renderer":"skwasm",'
                '"useLocalCanvasKit":true}'
            ),
            "index.html": "<html></html>",
            "main.dart.mjs": "export {};",
            "main.dart.wasm": "wasm",
            "assets/assets/shaders/doom_palette.wgslbundle": "shader",
        }
        for relative, contents in files.items():
            path = bundle / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents, encoding="utf-8")
        wad = bundle / "assets/.local/doom/DOOM1.WAD"
        wad.parent.mkdir(parents=True)
        shutil.copyfile(Path(".local/doom/DOOM1.WAD"), wad)
        (bundle / ".last_build_id").write_text("local-only", encoding="utf-8")
        return bundle

    def test_round_trip_preserves_hidden_iwad_and_omits_build_marker(self) -> None:
        archive = self.root / "bundle.tar.gz"
        destination = self.root / "deployed"

        pack(self._bundle(), archive)
        extract(archive, destination)

        self.assertEqual(
            (destination / "assets/.local/doom/DOOM1.WAD").stat().st_size,
            4_196_020,
        )
        self.assertFalse((destination / ".last_build_id").exists())

    def test_pack_rejects_worker_or_functions_configuration(self) -> None:
        bundle = self._bundle()
        (bundle / "_worker.js").write_text("export default {};", encoding="utf-8")

        with self.assertRaisesRegex(ArtifactError, "unsafe artifact"):
            pack(bundle, self.root / "bundle.tar.gz")

    def test_extract_rejects_path_traversal(self) -> None:
        archive = self.root / "malicious.tar.gz"
        with tarfile.open(archive, mode="w:gz") as output:
            info = tarfile.TarInfo("../escaped.txt")
            info.size = 1
            output.addfile(info, io.BytesIO(b"x"))

        with self.assertRaisesRegex(ArtifactError, "unsafe artifact path"):
            extract(archive, self.root / "deployed")
        self.assertFalse((self.root / "escaped.txt").exists())

    def test_pack_rejects_missing_changed_or_overridden_header_rules(self) -> None:
        bundle = self._bundle()
        headers_path = bundle / "_headers"
        expected = headers_path.read_text(encoding="utf-8")
        invalid_variants = [
            expected.replace("  Cross-Origin-Embedder-Policy: credentialless\n", ""),
            expected.replace("same-origin", "unsafe-none"),
            expected + "\n/*\n  ! Cross-Origin-Opener-Policy\n",
            expected.replace("public, max-age=0, must-revalidate", "public, max-age=31536000"),
        ]
        for contents in invalid_variants:
            with self.subTest(contents=contents):
                headers_path.write_text(contents, encoding="utf-8")
                with self.assertRaisesRegex(ArtifactError, "trusted header contract"):
                    pack(bundle, self.root / "bundle.tar.gz")


if __name__ == "__main__":
    unittest.main()
