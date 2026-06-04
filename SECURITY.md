# Security Policy

## Supported Versions

Security fixes are applied to the latest `v2.x` release and `main`.
Older majors do not receive backports.

## Reporting a Vulnerability

If you find a security issue — especially anything that could expose a
user's reMarkable cloud authentication token, leak data from their account,
or be triggered by a malicious notebook on the device — please **report it
privately** rather than opening a public issue.

Use GitHub's private vulnerability reporting:

- Go to <https://github.com/delize/remarkable-daily-journal/security/advisories/new>
- Or: repo → **Security** → **Report a vulnerability**

Include:
- A description of the issue and its impact
- Steps to reproduce, or a proof-of-concept
- The version (image tag / commit SHA) you tested against

You can expect an acknowledgement within **7 days** and a status update
within **30 days**. Coordinated disclosure timelines will be agreed
case-by-case.

## Scope

In scope:

- This repository's scripts, Dockerfile, and GitHub Actions workflows
- The container image at `ghcr.io/delize/remarkable-daily-journal`

Out of scope (please report upstream):

- Vulnerabilities in [`ddvk/rmapi`](https://github.com/ddvk/rmapi) itself
- Vulnerabilities in the reMarkable cloud API or device firmware
- Vulnerabilities in GitHub Actions or the Alpine/Go base images

## Credentials and Data

This project never transmits user data anywhere except to the reMarkable
cloud (via `rmapi`) and, if you explicitly opt in, to the GitHub Issues
API on your own repository (via `github-notify.sh`). The rmapi auth token
lives only in the container's `/app/.config/rmapi` volume; nothing in this
repository reads, exfiltrates, or logs it.
