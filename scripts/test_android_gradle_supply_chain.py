#!/usr/bin/env python3
"""Regression tests for Android Gradle repository and dependency trust policy."""

from __future__ import annotations

import re
import subprocess
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEPENDABOT = ROOT / ".github" / "dependabot.yml"
SETTINGS = ROOT / "SSRVPN_Android" / "android" / "settings.gradle.kts"
ROOT_BUILD = ROOT / "SSRVPN_Android" / "android" / "build.gradle.kts"
METADATA = (
    ROOT
    / "SSRVPN_Android"
    / "android"
    / "gradle"
    / "verification-metadata.xml"
)


class AndroidGradleSupplyChainTest(unittest.TestCase):
    def test_existing_android_configuration_guard_accepts_centralized_repositories(
        self,
    ) -> None:
        result = subprocess.run(
            ["bash", "scripts/check-android-built-in-kotlin.sh"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Android build configuration guard passed.", result.stdout)

    def test_dependabot_tracks_android_gradle_dependencies(self) -> None:
        config = DEPENDABOT.read_text(encoding="utf-8")
        self.assertRegex(
            config,
            re.compile(
                r'package-ecosystem:\s*"gradle".*?'
                r'directory:\s*"/SSRVPN_Android/android".*?'
                r'interval:\s*"weekly"',
                re.DOTALL,
            ),
        )

    def test_dependency_repositories_are_centralized_and_allowlisted(self) -> None:
        settings = SETTINGS.read_text(encoding="utf-8")
        root_build = ROOT_BUILD.read_text(encoding="utf-8")
        gradle_scripts = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (ROOT / "SSRVPN_Android" / "android").rglob("*.gradle.kts")
            if ".gradle" not in path.parts
        )

        self.assertIn("dependencyResolutionManagement", settings)
        self.assertIn("RepositoriesMode.PREFER_SETTINGS", settings)
        self.assertNotIn("RepositoriesMode.FAIL_ON_PROJECT_REPOS", settings)
        self.assertIn("Flutter 3.44.1's Gradle plugin", settings)
        self.assertIn("PREFER_SETTINGS ignores that project", settings)
        self.assertIn("google()", settings)
        self.assertIn("mavenCentral()", settings)
        self.assertIn("exclusiveContent", settings)
        self.assertIn('includeGroup("io.flutter")', settings)
        self.assertIn("https://storage.googleapis.com/download.flutter.io", settings)
        self.assertNotIn("aliyun.com", gradle_scripts.lower())
        self.assertNotRegex(root_build, r"(?s)allprojects\s*\{.*?repositories\s*\{")

    def test_dependency_verification_uses_sha256_for_every_artifact(self) -> None:
        self.assertTrue(METADATA.is_file(), "Gradle verification metadata is missing")
        root = ET.parse(METADATA).getroot()
        namespace = {"v": "https://schema.gradle.org/dependency-verification"}
        self.assertEqual(
            root.findtext("v:configuration/v:verify-metadata", namespaces=namespace),
            "true",
        )
        self.assertEqual(
            root.findtext("v:configuration/v:verify-signatures", namespaces=namespace),
            "false",
        )
        self.assertIsNone(root.find("v:configuration/v:trusted-artifacts", namespace))
        self.assertIsNone(root.find("v:configuration/v:ignored-keys", namespace))
        components = root.findall("v:components/v:component", namespace)
        self.assertGreater(len(components), 100)

        artifacts = root.findall("v:components/v:component/v:artifact", namespace)
        self.assertGreater(len(artifacts), 100)
        for artifact in artifacts:
            checksum_types = {
                child.tag.rsplit("}", 1)[-1]
                for child in artifact
            }
            self.assertEqual(
                checksum_types,
                {"sha256"},
                f"unexpected checksum policy for {artifact.attrib.get('name')}",
            )
            sha256 = artifact.findall("v:sha256", namespace)
            self.assertTrue(sha256, f"missing SHA-256 for {artifact.attrib.get('name')}")
            for checksum in sha256:
                value = checksum.attrib.get("value", "")
                self.assertRegex(value, r"^[0-9a-f]{64}$")


if __name__ == "__main__":
    unittest.main()
