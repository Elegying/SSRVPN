import importlib.util
import os
from pathlib import Path
import subprocess
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

    def test_certificate_supports_sdk36_and_sdk37_without_source_stamp(self):
        digest = "ab" * 32
        for label in ("Signer #1", "V1 Signer:", "V2 Signer:", "V3.0 Signer:", "V3.1 Signer:"):
            with self.subTest(label=label), patch.object(APK.subprocess, "check_output", return_value=(
                f"{label} certificate SHA-256 digest: {digest.upper()}\r\n"
                f"Source Stamp Signer: certificate SHA-256 digest: {'cd' * 32}\n"
            )):
                self.assertEqual(APK.certificate(Path("apksigner"), Path("app.apk")), [digest])

    def test_certificate_rejects_missing_malformed_and_unknown_output(self):
        for output in ("", "Source Stamp Signer: certificate SHA-256 digest: " + "ab" * 32,
                       "V2 Signer: certificate SHA-256 digest: ab",
                       "V2 Signer: certificate SHA-256 digest: " + "z" * 64,
                       "Unknown Signer: certificate SHA-256 digest: " + "ab" * 32,
                       "V2 Signer: certificate SHA-256 digest: " + "ab" * 32 +
                       "\nV2 Signer: certificate SHA-256 digest: incomplete"):
            with self.subTest(output=output), patch.object(APK.subprocess, "check_output", return_value=output):
                with self.assertRaisesRegex(ValueError, "certificate"):
                    APK.certificate(Path("apksigner"), Path("app.apk"))

    def test_certificate_preserves_every_signer(self):
        output = "\n".join(f"V2 Signer: certificate SHA-256 digest: {digest}" for digest in ["cd" * 32, "ab" * 32])
        with patch.object(APK.subprocess, "check_output", return_value=output):
            self.assertEqual(APK.certificate(Path("apksigner"), Path("app.apk")), ["ab" * 32, "cd" * 32])

    def test_certificate_never_accepts_failed_verification(self):
        with patch.object(APK.subprocess, "check_output", side_effect=subprocess.CalledProcessError(1, "apksigner")):
            with self.assertRaises(subprocess.CalledProcessError):
                APK.certificate(Path("apksigner"), Path("app.apk"))

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


@unittest.skipUnless(os.environ.get("SSRVPN_TEST_APK_SDK") == "1", "explicit Android SDK integration test")
class SdkOptimizerTest(unittest.TestCase):
    def test_real_signed_apk_round_trip_with_installed_build_tools(self):
        sdk = Path(os.environ["ANDROID_HOME"])
        tools = sorted(path.parent for path in (sdk / "build-tools").glob("*/apksigner"))
        self.assertTrue(tools, "Android SDK build-tools are required")
        with tempfile.TemporaryDirectory(prefix="ssrvpn-apk-sdk-") as directory:
            root = Path(directory)
            manifest = root / "AndroidManifest.xml"
            manifest.write_text('<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
                                'package="com.ssrvpn.optimizer.fixture"><uses-sdk android:minSdkVersion="24" '
                                'android:targetSdkVersion="36"/><application android:hasCode="false"/></manifest>')
            unsigned, source, destination, key = (root / name for name in ("unsigned.apk", "signed.apk", "optimized.apk", "key.jks"))
            subprocess.run([str(tools[-1] / "aapt2"), "link", "--manifest", str(manifest),
                            "-I", str(sdk / "platforms/android-36/android.jar"), "-o", str(unsigned)], check=True)
            with zipfile.ZipFile(unsigned, "a") as archive:
                archive.writestr("assets/payload.txt", b"preserve all resources\n" * 4096,
                                 compress_type=zipfile.ZIP_DEFLATED)
            subprocess.run(["keytool", "-genkeypair", "-keystore", str(key), "-alias", "fixture",
                            "-storepass", "fixture-password", "-keypass", "fixture-password",
                            "-keyalg", "RSA", "-validity", "1", "-dname", "CN=SDK fixture"],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            with patch.dict(os.environ, {"SSRVPN_APK_STORE_PASSWORD": "fixture-password",
                                         "SSRVPN_APK_KEY_PASSWORD": "fixture-password"}):
                for build_tools in tools:
                    with self.subTest(build_tools=build_tools.name):
                        subprocess.run([str(build_tools / "apksigner"), "sign", "--ks", str(key),
                                        "--ks-pass", "env:SSRVPN_APK_STORE_PASSWORD", "--ks-key-alias", "fixture",
                                        "--v4-signing-enabled", "false", "--out", str(source), str(unsigned)], check=True)
                        APK.optimize(source, destination, build_tools, key, "fixture")
                        self.assertEqual(APK.payload(source), APK.payload(destination))
                        self.assertEqual(APK.certificate(build_tools / "apksigner", source),
                                         APK.certificate(build_tools / "apksigner", destination))


if __name__ == "__main__":
    unittest.main()
