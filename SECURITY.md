# Security Policy

## Supported Versions

We only support security updates for the latest version of Froggy.

| Version | Supported          |
| ------- | ------------------ |
| latest  | :white_check_mark: |

## Reporting a Vulnerability

**Do not open a public issue.** Please report security vulnerabilities privately:

- **Telegram:** [@froggychips](https://t.me/froggychips)
- **Email:** big@froggychips.xyz

## Threat Model & Privacy

- **Local-Only:** No screen data or OCR text is ever sent to any cloud provider.
- **Redaction:** `Redactor` strips secrets (API keys, JWTs) **before** disk write.
