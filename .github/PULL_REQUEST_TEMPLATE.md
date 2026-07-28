## Summary

<!-- What problem does this pull request solve, and why is this change needed? -->

## Changes

<!-- Describe the important behavior and implementation changes. -->

## Related issue

<!-- Use "Closes #123" when applicable. Small maintenance changes do not require an issue. -->

## Validation

<!-- Check every applicable item. Explain any item that is intentionally not applicable. -->

- [ ] `./script/build_and_run.sh --verify`
- [ ] Relevant XCTest coverage
- [ ] Signed Runtime validation with `./script/build_and_install.sh`
- [ ] Real USB/WireGuard validation
- [ ] Not applicable; explanation:

## User-facing impact

<!-- Include screenshots for UI changes and note documentation or release-note impact. -->

## Security and architecture

<!-- Describe changes to USB, VM lifecycle, WireGuard, Network System Extension, VM Assets, signing, privacy, or key handling. Write "None" when there is no impact. -->

## Checklist

- [ ] The pull request has one focused purpose.
- [ ] The title follows Conventional Commits, for example `fix(usb): serialize detach handling`.
- [ ] Behavior changes include appropriate tests or an explanation of why automated testing is not practical.
- [ ] User-facing behavior and operational changes are documented.
- [ ] New, moved, renamed, or deleted Swift files are reflected in Xcode groups, target membership, and build phases.
- [ ] No private keys, complete WireGuard client configurations, credentials, provisioning profiles, personal signing values, or local build artifacts are included.
- [ ] Guest VM scripts and VM Asset build tooling remain in `Afcoo/ThruRNDIS_VM_Assets`.
