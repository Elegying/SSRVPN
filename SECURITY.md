# Security Policy

## Supported Versions

Security fixes should target the current `2.x` line unless a release branch states otherwise.

## Reporting a Vulnerability

Do not open public issues for vulnerabilities involving credentials, proxy bypass, privilege escalation, update delivery, or crash dump leakage.

Send a private report to the project maintainer with:

- Affected platform and version.
- Reproduction steps.
- Expected and actual behavior.
- Relevant logs with secrets redacted.

## Secret Handling

SSRVPN logs should redact:

- API secrets.
- Password fields.
- Bearer tokens.
- Subscription or proxy credentials.

When adding new logging, route sensitive text through shared redaction helpers or avoid logging the sensitive value entirely.

## macOS TUN Privilege Model

macOS TUN mode requires the Clash core binary (`AtlasCore`) to run with root privileges to create a virtual network interface. SSRVPN uses setuid root:

1. On first TUN activation, SSRVPN prompts for administrator credentials via `osascript`.
2. The core binary is chowned to `root:wheel` and given the setuid bit (`chmod u+s`).
3. Subsequent TUN activations run without re-prompting, as long as the binary is unchanged.

**Security implications:**
- Any local user can execute the core with root privileges (setuid inheritance).
- If the core binary is replaced (e.g. by an update), the setuid bit is lost and must be re-granted.
- SSRVPN verifies the binary owner and setuid bit before each launch; mismatches trigger a re-authorization prompt.
- The core binary is never writable by non-root users after authorization.

**If you suspect privilege tampering:**
```bash
# Check core ownership and permissions
stat -f '%Su %Mp%Lp' /path/to/AtlasCore
# Should show: root -rwsr-xr-x (owner=root, setuid bit set)

# Revoke if needed
sudo chown root:wheel /path/to/AtlasCore
sudo chmod u-s /path/to/AtlasCore
```

## Android apiSecret Storage

Android stores the Clash API secret in `EncryptedSharedPreferences` (AES-256 via Android Keystore). Prior versions used Base64-encoded `SharedPreferences`, which is not secure. On upgrade, SSRVPN automatically migrates the secret to encrypted storage and deletes the old key.

**Never** store apiSecret in:
- Plaintext files
- Base64-encoded SharedPreferences (legacy, auto-migrated)
- Build-time constants or source code

