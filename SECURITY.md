# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| main (development) | ✅ |
| tagged releases | ✅ (latest two minor versions) |

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, use one of these:

1. **GitHub Security Advisories** (preferred):
   [Report a vulnerability](https://github.com/Neyam-OpenSc/neyam-vaani/security/advisories/new)
2. **Email**: security@neyamopensc.org *(encrypted preferred — key published on first release)*

Please include:

- What you found and its potential impact
- Steps or a proof-of-concept to reproduce it
- Affected version / commit

## What we especially care about

Neyam Vaani handles sensitive data entirely on-device (by design), so we
pay special attention to:

- The encrypted storage layer (SQLCipher) and key handling (Android Keystore)
- Data leakage through logs, caches, or crash output
- Language pack delivery (signature verification before install)
- Permission handling (no silent escalation, no request-permission creep)
- The native bridges (memory safety at the JNI boundary)

## Response timeline

- **Acknowledgement**: within 72 hours
- **Assessment & triage**: within 7 days
- **Fix**: critical issues prioritized for the next release
- **Disclosure**: coordinated, after a fix ships (typically 90 days)

## Scope

Everything in this repository is in scope, including documentation that
describes security behavior. Dependencies are in scope via our own
integration of them — upstream bugs should also be reported upstream.

Thank you for helping keep Vaani's users safe. 🙏
