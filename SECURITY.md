# Security Policy

ThruRNDIS handles USB passthrough, a privileged macOS network helper, and a
Virtualization framework VM. Please report suspected vulnerabilities privately
and avoid exposing sensitive material in a public issue.

## Supported versions

Security fixes are developed for the latest published release and the current
`main` branch. Older releases may be asked to upgrade before a report is
investigated or fixed.

## Reporting a vulnerability

Use GitHub's private
[security advisory form](https://github.com/Afcoo/ThruRNDIS/security/advisories/new).
Do not open a public issue for a suspected vulnerability.

Include only the information needed to reproduce and assess the report:

- affected ThruRNDIS version and build;
- macOS version and hardware;
- affected component and security impact;
- reproducible steps or a minimal proof of concept;
- whether exploitation requires USB access, administrator approval, helper
  registration, or signing;
- suggested mitigations, if known.

Do not submit Apple signing credentials, notary credentials, provisioning
profiles, or unrelated personal data. Replace secrets with clearly marked test
values.

Reports involving the published guest kernel, initramfs, or VM Asset release
pipeline should be submitted privately to
[Afcoo/ThruRNDIS_VM_Assets](https://github.com/Afcoo/ThruRNDIS_VM_Assets/security)
when that repository is the affected component.

The maintainer will make a best effort to acknowledge a complete report within
seven days, assess its scope, and coordinate remediation and disclosure.
Please allow reasonable time for a fix before publishing details.

## Security-sensitive areas

Reports are especially useful when they involve:

- privileged-helper authentication, authorization, Bond/feth/bridge ownership,
  Network Service ownership, route configuration, or cleanup;
- unintended persistence, alteration, or replacement of the managed IPv4
  router, DNS, or Network Service priority;
- adding an unowned interface to a bridge or removing an unrelated Bond, feth
  pair, bridge member, or SystemConfiguration service;
- USB AccessoryAccess approval and passthrough lifecycle;
- VM Asset download, checksum validation, archive extraction, or promotion;
- signing, entitlements, notarization, release artifacts, or update metadata;
- unintended packet routing, privilege escalation, sandbox escape, or secret
  disclosure.

General bugs without a security impact should use the public Bug Report form.
