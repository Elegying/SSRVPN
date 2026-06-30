# Release Signing

This project can build release artifacts without private signing material. Public production releases should use repository secrets and sign artifacts during the release workflow.

Never commit keystores, certificates, provisioning material, notarization passwords, or code-signing tokens.

## Android

The Android Gradle build already reads `SSRVPN_Android/android/key.properties` when it exists and falls back to debug signing when it does not.

Recommended repository secrets:

- `ANDROID_KEYSTORE_BASE64`: Base64 encoded `.jks` or `.keystore` file.
- `ANDROID_KEYSTORE_PASSWORD`: Keystore password.
- `ANDROID_KEY_ALIAS`: Release key alias.
- `ANDROID_KEY_PASSWORD`: Release key password.

Release workflow steps should:

1. Decode `ANDROID_KEYSTORE_BASE64` into a temporary file.
2. Generate `SSRVPN_Android/android/key.properties` with paths and passwords.
3. Run `flutter build apk --release`.
4. Delete the temporary keystore and `key.properties` before artifact upload.

## macOS

`SSRVPN_MacOS/tool/package_macos.sh` currently performs ad-hoc signing so local DMG packaging is self-consistent. Public distribution should replace that with Developer ID signing and notarization.

Recommended repository secrets:

- `MACOS_DEVELOPER_ID_APPLICATION_P12_BASE64`: Base64 encoded Developer ID Application certificate.
- `MACOS_DEVELOPER_ID_APPLICATION_PASSWORD`: Certificate password.
- `MACOS_NOTARY_APPLE_ID`: Apple ID used for notarization.
- `MACOS_NOTARY_TEAM_ID`: Apple Developer Team ID.
- `MACOS_NOTARY_PASSWORD`: App-specific password or keychain profile credential.

Release workflow steps should:

1. Import the certificate into a temporary keychain.
2. Sign `SSRVPN.app` with Developer ID Application identity.
3. Build the DMG.
4. Submit with `xcrun notarytool submit --wait`.
5. Staple the notarization ticket with `xcrun stapler staple`.
6. Verify with `codesign --verify --deep --strict` and `spctl`.

## Windows

The Windows ZIP is portable and currently unsigned. Public distribution should sign the executable and native DLLs before packaging.

Recommended repository secrets:

- `WINDOWS_CODESIGN_PFX_BASE64`: Base64 encoded `.pfx` certificate.
- `WINDOWS_CODESIGN_PFX_PASSWORD`: Certificate password.
- `WINDOWS_CODESIGN_TIMESTAMP_URL`: Timestamp server URL.

Release workflow steps should:

1. Decode the PFX certificate into a temporary file.
2. Build the Windows release.
3. Sign `SSRVPN.exe` and bundled native DLLs with `signtool`.
4. Verify signatures before ZIP packaging.
5. Delete the temporary certificate before artifact upload.

## Release Gate

Before publishing a public release:

1. Confirm `main` CI is green.
2. Confirm signing secrets are present for every platform being published.
3. Build artifacts from a version tag.
4. Verify checksums and signatures from downloaded release artifacts.
5. Smoke test installation and launch on clean machines.
