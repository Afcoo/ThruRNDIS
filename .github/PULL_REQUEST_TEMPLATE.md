## Summary

<!-- What problem does this pull request solve, and why is this change needed? -->

## Changes

<!-- Describe the important behavior and implementation changes. -->

## Related issue

<!-- Use "Closes #123" when applicable. Small maintenance changes do not require an issue. -->

## Validation

<!-- Check every applicable item. Explain any item that is intentionally not applicable. -->

- [ ] `./script/build_and_run.sh --verify`
- [ ] Checks run and unverified runtime paths are documented
- [ ] Signed Runtime validation with `./script/build_and_install.sh`
- [ ] Real USB/VZNAT route validation
- [ ] Not applicable; explanation:

## User-facing impact

<!-- Include screenshots for UI changes and note documentation or release-note impact. -->

## Security and architecture

<!-- Describe changes to USB, VM lifecycle, VZNAT host routes, the privileged helper, VM Assets, signing, security, or privacy. Write "None" when there is no impact. -->

## Checklist

- [ ] The pull request has one focused purpose.
- [ ] The title follows Conventional Commits, for example `fix(usb): serialize detach handling`.
- [ ] Behavior changes include appropriate build or runtime validation, with unavailable paths explained.
- [ ] User-facing behavior and operational changes are documented.
- [ ] New, moved, renamed, or deleted Swift files are reflected in Xcode groups, target membership, and build phases.
- [ ] No credentials, provisioning profiles, personal signing values, or local build artifacts are included.
- [ ] Guest VM scripts and VM Asset build tooling remain in `Afcoo/ThruRNDIS_VM_Assets`.
