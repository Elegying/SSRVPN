import base64
import unittest

from scripts.validate_release_signing import SigningConfigurationError, validate


class ValidateReleaseSigningTest(unittest.TestCase):
    def test_disabled_signing_requires_no_credentials(self) -> None:
        self.assertFalse(validate("macos", {}))
        self.assertFalse(validate("windows", {"WINDOWS_SIGNING_ENABLED": "false"}))

    def test_enabled_signing_reports_variable_names_only(self) -> None:
        with self.assertRaisesRegex(
            SigningConfigurationError,
            "WINDOWS_CERTIFICATE_PFX_BASE64, WINDOWS_CERTIFICATE_PASSWORD",
        ):
            validate("windows", {"WINDOWS_SIGNING_ENABLED": "true"})

    def test_complete_windows_configuration_is_accepted(self) -> None:
        environment = {
            "WINDOWS_SIGNING_ENABLED": "true",
            "WINDOWS_CERTIFICATE_PFX_BASE64": base64.b64encode(b"pfx").decode(),
            "WINDOWS_CERTIFICATE_PASSWORD": "secret-value",
        }
        self.assertTrue(validate("windows", environment))

    def test_complete_macos_configuration_is_accepted(self) -> None:
        environment = {
            "MACOS_SIGNING_ENABLED": "true",
            "MACOS_CERTIFICATE_P12_BASE64": base64.b64encode(b"p12").decode(),
            "MACOS_CERTIFICATE_PASSWORD": "certificate-password",
            "MACOS_SIGNING_IDENTITY": "Developer ID Application: Example",
            "APPLE_NOTARY_APPLE_ID": "developer@example.com",
            "APPLE_NOTARY_TEAM_ID": "TEAM123456",
            "APPLE_NOTARY_PASSWORD": "app-password",
        }
        self.assertTrue(validate("macos", environment))

    def test_malformed_certificate_is_rejected_without_echoing_value(self) -> None:
        malformed = "not-a-secret-certificate"
        environment = {
            "WINDOWS_SIGNING_ENABLED": "true",
            "WINDOWS_CERTIFICATE_PFX_BASE64": malformed,
            "WINDOWS_CERTIFICATE_PASSWORD": "secret-value",
        }
        with self.assertRaises(SigningConfigurationError) as context:
            validate("windows", environment)
        self.assertNotIn(malformed, str(context.exception))

    def test_invalid_enable_flag_fails_closed(self) -> None:
        with self.assertRaisesRegex(SigningConfigurationError, "must be true or false"):
            validate("windows", {"WINDOWS_SIGNING_ENABLED": "maybe"})


if __name__ == "__main__":
    unittest.main()
