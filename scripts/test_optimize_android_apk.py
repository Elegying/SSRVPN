import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile


SPEC = importlib.util.spec_from_file_location(
    "optimize_apk", Path(__file__).with_name("optimize-android-apk.py"))
APK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APK)


class OptimizeApkTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def archive(self, name, content=b"native-core", signature=b"signature"):
        path = self.root / name
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("lib/arm64-v8a/libgojni.so", content,
                             compress_type=zipfile.ZIP_DEFLATED)
            archive.writestr("resources.arsc", b"resources")
            archive.writestr("META-INF/CERT.SF", signature)
            archive.writestr("META-INF/library.kotlin_module", b"metadata")
        return path

    def test_only_signature_metadata_may_change(self):
        first = self.archive("first.apk")
        second = self.archive("second.apk", signature=b"new signature")
        self.assertEqual(APK.payload(first), APK.payload(second))
        self.assertIn("META-INF/library.kotlin_module", APK.payload(first))
        self.assertEqual(APK.payload(first)["resources.arsc"][0], zipfile.ZIP_STORED)
        self.archive("second.apk", content=b"different-core")
        self.assertNotEqual(APK.payload(first), APK.payload(second))

    def test_duplicate_entries_are_rejected(self):
        source = self.archive("source.apk")
        with zipfile.ZipFile(source, "a") as archive:
            with self.assertWarns(UserWarning):
                archive.writestr("resources.arsc", b"changed")
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            APK.payload(source)

    def exercise(self, changed_payload=False, changed_signer=False, larger=False):
        source = self.archive("source.apk", signature=b"s" * 4096)
        destination = self.root / "output.apk"
        destination.write_bytes(b"previous output")
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            if "sign" in command:
                signed = Path(command[command.index("--out") + 1])
                created = self.archive(
                    "candidate.apk",
                    content=b"changed" if changed_payload else b"native-core",
                    signature=b"s" * (8192 if larger else 1))
                signed.write_bytes(created.read_bytes())

        certificates = [["original"], ["other" if changed_signer else "original"]]
        with patch.dict(APK.os.environ, {
            "SSRVPN_APK_STORE_PASSWORD": "test", "SSRVPN_APK_KEY_PASSWORD": "test"
        }), patch.object(APK, "certificate", side_effect=certificates), \
                patch.object(APK.subprocess, "run", side_effect=run):
            if changed_payload or changed_signer:
                with self.assertRaises(ValueError):
                    APK.optimize(source, destination, self.root, self.root / "key", "key")
                self.assertEqual(destination.read_bytes(), b"previous output")
            else:
                APK.optimize(source, destination, self.root, self.root / "key", "key")
                self.assertEqual(APK.payload(source), APK.payload(destination))
                self.assertLessEqual(destination.stat().st_size, source.stat().st_size)
                if larger:
                    self.assertEqual(destination.read_bytes(), source.read_bytes())
        self.assertEqual(calls[0][1:5], ["-z", "-P", "16", "4"])
        if not (changed_payload or changed_signer):
            self.assertEqual(calls[-1][1:5], ["-c", "-P", "16", "4"])
        self.assertEqual(list(self.root.glob(".apk-optimize-*")), [])

    def test_recompression_preserves_payload_and_alignment(self):
        self.exercise()

    def test_payload_change_preserves_previous_output(self):
        self.exercise(changed_payload=True)

    def test_signer_change_preserves_previous_output(self):
        self.exercise(changed_signer=True)

    def test_larger_candidate_retains_original(self):
        self.exercise(larger=True)


if __name__ == "__main__":
    unittest.main()
