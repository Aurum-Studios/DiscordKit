# File: Tools/ci/test_teamcity_artifact_transport.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Exercise the TeamCity artifact transport's ordered and exact reconstruction."""

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import teamcity_artifact_transport as transport


class TeamCityArtifactTransportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.original = self.root / "original.tar.gz"
        self.parts = self.root / "parts"
        self.restored = self.root / "restored.tar.gz"
        self.data = b"\x00abcdef\xff"
        self.original.write_bytes(self.data)
        transport.split(self.original, self.parts, part_size=3)

    def read_manifest(self):
        return json.loads((self.parts / transport.MANIFEST).read_text(encoding="utf-8"))

    def write_manifest(self, manifest):
        (self.parts / transport.MANIFEST).write_text(json.dumps(manifest), encoding="utf-8")

    def assert_rejected(self, message):
        with self.assertRaisesRegex(ValueError, message):
            transport.join(self.parts, self.restored)
        self.assertFalse(self.restored.exists())

    def test_round_trip_manifest_matches_archive_and_parts(self):
        manifest = self.read_manifest()
        self.assertEqual(manifest["size"], len(self.data))
        self.assertEqual(manifest["sha256"], hashlib.sha256(self.data).hexdigest())
        self.assertEqual([(part["name"], part["size"]) for part in manifest["parts"]],
                         [("part-0000", 3), ("part-0001", 3), ("part-0002", 2)])
        for part in manifest["parts"]:
            data = (self.parts / part["name"]).read_bytes()
            self.assertEqual(part["sha256"], hashlib.sha256(data).hexdigest())
        transport.join(self.parts, self.restored)
        self.assertEqual(self.restored.read_bytes(), self.data)

    def test_missing_or_unexpected_part_is_rejected(self):
        unexpected = self.parts / "part-0003"
        unexpected.write_bytes(b"unexpected")
        self.assert_rejected("inventory")
        unexpected.unlink()
        (self.parts / "part-0001").unlink()
        self.assert_rejected("inventory")

    def test_reordered_part_manifest_is_rejected(self):
        manifest = self.read_manifest()
        manifest["parts"].reverse()
        self.write_manifest(manifest)
        self.assert_rejected("order")

    def test_corrupt_or_oversize_part_leaves_no_archive(self):
        part = self.parts / "part-0001"
        for contents in (b"bad", b"too long", b"x"):
            with self.subTest(contents=contents):
                part.write_bytes(contents)
                self.assert_rejected("part failed verification")

    def test_symlink_part_is_rejected(self):
        part = self.parts / "part-0001"
        part.unlink()
        part.symlink_to(self.original)
        self.assert_rejected("Invalid TeamCity artifact part")

    def test_mismatched_whole_archive_digest_leaves_no_archive(self):
        manifest = self.read_manifest()
        manifest["sha256"] = "0" * 64
        self.write_manifest(manifest)
        self.assert_rejected("archive digest")

    def test_destinations_are_never_overwritten(self):
        with self.assertRaises(FileExistsError):
            transport.split(self.original, self.parts)
        self.restored.write_bytes(b"existing")
        with self.assertRaises(FileExistsError):
            transport.join(self.parts, self.restored)
        self.assertEqual(self.restored.read_bytes(), b"existing")

    def test_empty_archive_round_trips(self):
        self.original.write_bytes(b"")
        empty_parts = self.root / "empty"
        transport.split(self.original, empty_parts)
        self.assertEqual({item.name for item in empty_parts.iterdir()}, {transport.MANIFEST})
        transport.join(empty_parts, self.restored)
        self.assertEqual(self.restored.read_bytes(), b"")


if __name__ == "__main__":
    unittest.main()
