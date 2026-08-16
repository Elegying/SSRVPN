## Summary

-

## Scope

- [ ] Shared package
- [ ] Android
- [ ] macOS
- [ ] Windows
- [ ] CI/release/docs

## Verification

- [ ] `scripts/check-quality-hygiene.sh`
- [ ] `scripts/check-shared-barrel-imports.sh`
- [ ] `scripts/workspace.sh analyze`
- [ ] `scripts/workspace.sh test`
- [ ] `make verify` before merge, or the PR explains why a target-platform gate must run in CI

## Security and compatibility

- [ ] No secrets, private subscription data, generated artifacts, or untrusted input are logged or committed.
- [ ] HTTP subscription compatibility, the tested Android domestic-app bypass policy, IPv4-only routing, and the two-page product surface remain unchanged unless this PR explicitly replaces a documented decision.
- [ ] Native lifecycle, system proxy, TUN, installer, or release changes include target-platform evidence.

## Release Notes

-

## Risk

-
