# Contributing

Thanks for your interest. This project is a small Docker-based tool, so the
contribution process is intentionally lightweight.

## Quick start

```bash
git clone https://github.com/delize/remarkable-daily-journal
cd remarkable-daily-journal

# Install local dev deps (macOS)
brew install shellcheck bats-core jq

# Or on Ubuntu/Debian
sudo apt-get install shellcheck bats jq

# Run the full test suite
bats tests/*.bats

# Lint
shellcheck --severity=warning *.sh scripts/*.sh

# Bash syntax check
for f in *.sh scripts/*.sh; do bash -n "$f"; done
```

CI runs the same three checks plus a Docker build.

## Branches and PRs

- Branch from `main` with a descriptive name (e.g. `fix-cleanup-window`,
  `add-rmppm-templates`).
- Keep PRs focused — one logical change per PR.
- Update or add Bats tests for behavioral changes.
- Update `README.md` and `docs/templates/` if user-facing behavior changes.
- The Bats suite, Shellcheck, and a Docker build must pass before merge.

## What's helpful to contribute

- **Cross-device verification** — the generator and stencil are heavily tested
  on reMarkable Paper Pro. Confirmation that journals render correctly on
  reMarkable 1 / 2 / Paper Pro Move (or fixes if they don't) is welcome.
- **New friendly aliases** for `TEMPLATE_STYLE` — anything more common than the
  current `blank` / `lined` / `grid` / `checklist`.
- **Workflow improvements** — e.g. matrix splitting the biweekly template
  refresh, better diff output in the auto-update PR body.
- **Documentation** — clarifications, screenshots, deployment guides for
  specific NAS platforms.

## What to avoid

- **Don't commit `.rmdoc` files or anything from `/app/.config/rmapi/`** —
  these contain device state or auth tokens. `.gitignore` covers the common
  cases.
- **Don't pin major-version Actions** (`uses: actions/checkout@main` etc.).
  Use a tagged release or commit SHA.
- **Don't widen the cleanup heuristic** without thinking carefully — it
  deletes notebooks from the cloud, so false positives mean lost work. Keep
  the `stale AND empty` invariant; verify with `CLEANUP_DRY_RUN=true`.

## Releases

Maintainer-only. Tagging `vX.Y.Z` triggers a release build that publishes
versioned images to GHCR.

## Security

Security issues should be reported privately — see [`SECURITY.md`](SECURITY.md).
