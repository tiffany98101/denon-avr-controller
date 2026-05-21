# RELEASE_PLAN.md

## 1. Divergence audit

Baseline used for this audit:

- Remote fetched: `origin` (`git@github.com:tiffany98101/denon-avr-controller.git`)
- Current branch: `main`
- Current committed `HEAD`: `5ab7422 ARCHITECTURE.md v2: reconcile with local working tree`
- Fetched public mirror ref: `origin/main`
- Result: `HEAD` and `origin/main` are currently the same commit.

### Commits in `origin/main..HEAD`

There are no commits in `origin/main..HEAD` after `git fetch origin`.

| Commit | Summary | Classification | Notes |
|---|---|---|---|
| _none_ | _No committed divergence from `origin/main`_ | SAFE TO PUSH | Nothing to push for committed history. |

### Files newly present in the public mirror

Because `origin/main` already equals `HEAD`, the public mirror already contains the major v1.2.0-beta.3 tree shape: MPRIS daemon, test harness, RPM packaging, completions, man page, PowerShell module, docs, screenshots, and research references.

No committed files are currently “local only” relative to `origin/main`.

### Dirty working tree not covered by `origin/main..HEAD`

These changes are local working-tree changes, not committed divergence. They must be reviewed, committed, and pushed separately if they are intended for the next public release.

| Path | State | Classification | Notes |
|---|---:|---|---|
| `ARCHITECTURE.md` | modified | NEEDS REVIEW | Contains per-profile cache and write-race decision record updates. Good release material, but this is not yet committed. |
| `denon.sh` | modified | NEEDS REVIEW | Contains per-profile IP cache implementation. Needs normal release validation before public push. |
| `tests/test_profile_ip_cache.py` | untracked | NEEDS REVIEW | New pytest coverage for profile-scoped cache behavior. Must be added with the implementation if released. |
| `RELEASE_PLAN.md` | untracked | NEEDS REVIEW | Planning artifact from this task. Decide whether this belongs in the repo or should remain local. |

### Public-safety scan findings

Current committed tree contains example/private LAN IPs and one personal local path. These are not necessarily secrets, but they fail the requested pre-push hygiene checklist as written and should be cleaned or explicitly waived before the next public release.

- `README.md` contains `/home/administrator/organized_projects/denon/denon_main`.
- `README.md` contains live-looking examples such as `192.168.1.162`.
- `man/denon.1`, `denon.sh`, `denon-mpris.service`, PowerShell docs, and research docs contain `192.168.1.100` or `192.168.1.23` examples.
- `references/appcommand_get_verbs.json` says a live probe came from `192.168.1.100`.
- No `.env`, credential, secret, or token files were found by filename scan.

Important release metadata issue:

- `VERSION` is `1.2.0-beta.3`.
- Tag `v1.2.0-beta.3` already exists and points behind current `HEAD`.
- `make tag` would try to create `v1.2.0-beta.3` again and fail unless the maintainer intentionally changes version metadata first.
- The RPM spec also points at `v1.2.0-beta.3` via `%global tag_name v%{version_base}-%{pre_tag}`.

Decision needed before tagging: choose the next public version, likely `1.2.0-beta.4` or `1.2.0`, and update `VERSION`, `rpm/denon-avr-controller.spec`, and changelog/release notes together.

## 2. Pre-push checklist

Run this before any push or release tag:

- [ ] `git fetch origin`
- [ ] `git status --short` is understood; no accidental untracked files
- [ ] `git log --oneline origin/main..HEAD` contains only commits intended for public release
- [ ] No `DENON_IP` literals with private IPs in committed files: grep for `192.168.`, `10.`, and `172.16-31.`
- [ ] No personal home paths such as `/home/administrator` in code or docs
- [ ] No `.env`, credentials, tokens, private keys, receiver dumps, or local logs staged
- [ ] `VERSION` matches the intended public version
- [ ] `rpm/denon-avr-controller.spec` `%global version_base`, `%global pre_tag`, `%global rpm_release`, `Source0`, and `%changelog` match the intended public version
- [ ] The intended git tag does not already exist locally or remotely
- [ ] CHANGELOG entry exists for the version
- [ ] README.md describes what users see in the public repo, not local-only workspace paths
- [ ] README examples use documentation IPs such as `192.0.2.10`, not a real LAN address
- [ ] `ARCHITECTURE.md` §7.11 will be updated post-push to reflect the mirror state
- [ ] `bash -n denon.sh`
- [ ] `zsh -n denon.sh`
- [ ] `pytest -q`
- [ ] `shellcheck -s bash denon.sh` if ShellCheck is installed
- [ ] `make -f .copr/Makefile srpm outdir=/tmp/copr-out` or `make srpm` succeeds after the tag/version decision

## 3. Suggested commit/PR sequence

### Recommendation

Use several smaller logical PRs for the remaining dirty-tree work. Do not use an umbrella PR for the already-committed v1.2.0-beta.3 tree, because `origin/main` already contains that history.

The public mirror is already at local committed `HEAD`. The next useful sequence is:

1. Release hygiene PR
   - Remove local workspace path from `README.md`.
   - Replace live/private IP examples with documentation addresses.
   - Add or update `CHANGELOG.md`.
   - Decide whether to keep `RELEASE_PLAN.md` in repo or leave it local.

2. Per-profile IP cache PR
   - Include `denon.sh`, `ARCHITECTURE.md`, and `tests/test_profile_ip_cache.py`.
   - This should land as one coherent behavior change because it changes cache path semantics for profiled users.

3. Version/tag preparation PR
   - Update `VERSION`.
   - Update `rpm/denon-avr-controller.spec` globals and `%changelog`.
   - Update release notes/CHANGELOG for the chosen version.
   - Run SRPM generation locally before tagging.

Why smaller PRs:

- The public mirror already has the big MPRIS/test/RPM/data-family sync, so an umbrella sync PR would mix already-public work with new unreleased behavior.
- The dirty-tree changes have separable risk: cache path behavior and release hygiene.
- Smaller PRs make it easier to revert one behavior without backing out unrelated docs or packaging.

If the maintainer wants a single release branch anyway, use one branch containing the four groups above, but preserve the logical commits.

## 4. Draft release notes

Current `VERSION`: `1.2.0-beta.3`

Release blocker: `v1.2.0-beta.3` already exists and is behind `HEAD`. These notes should be used for the maintainer-selected next version, not blindly tagged as `v1.2.0-beta.3`.

### Highlights

- Public tree now includes the reconciled Bash CLI, MPRIS2 bridge, pytest harness, RPM packaging, completions, man page, PowerShell module, data inventory commands, dashboard improvements, and architecture contract.
- Optional MPRIS2 bridge exposes the receiver to Plasma/KDE media controls through a systemd user service.
- Receiver diagnostics and data inventory are now first-class CLI surfaces.

### New features

- `denon-mpris` MPRIS2 D-Bus bridge with systemd user unit.
- HEOS helper integration for queue/group/browse/search/play-stream workflows.
- `data` command family: fields, dump, discover, capabilities, and summary.
- `dashboard` diagnostics, watch mode, color controls, source lists, now-playing details, and event logging.
- Snapshot and diff workflow for receiver XML state.
- Bash and zsh completions.
- Fedora RPM/COPR packaging files.
- Per-profile IP cache path: `~/.cache/denon_ip.<profile>` when `DENON_PROFILE` is active.

### Architectural changes

- `ARCHITECTURE.md` is now the project-truth contract for future changes.
- §4.3 documents TTL-bounded discovery and profile-scoped cache behavior.
- §4.4 documents layered config and profiles.
- §4.11 documents the nested-function promotion test seam.
- §6.1 documents the MPRIS daemon boundary.
- §6.5 documents Makefile/RPM packaging workflow.

### Breaking changes

- No intentional breaking CLI changes are identified.
- Profile-scoped IP cache is additive for users who set `DENON_PROFILE`; users without `DENON_PROFILE` continue using `~/.cache/denon_ip`.

### Upgrade notes

- For CLI-only users, continue using `denon status`, `denon vol`, and existing commands as before.
- For profile users, run `denon setip <ip>` once per active `DENON_PROFILE` if they want warm per-profile caches immediately.
- For MPRIS bridge users, install with `make install-mpris` or the RPM package, then enable the user unit with `systemctl --user enable --now denon-mpris.service`.
- For packaged Fedora/COPR users, ensure the release tag, `VERSION`, and RPM spec version metadata all match before triggering a build.

## 5. README.md delta

Committed `README.md` is identical to `origin/main:README.md` after fetch. There is no committed README delta to push right now.

Recommended README updates before the next public release:

### Remove local workspace path

Before:

```text
For local development in this workspace, the active repository path is:

/home/administrator/organized_projects/denon/denon_main
```

After:

```text
For local development, run commands from the repository root.
```

### Replace live-looking IP examples

Before:

```bash
export DENON_IP=192.168.1.162
./denon.sh setip 192.168.1.162
DENON_IP=192.168.1.162
DENON_DEFAULT_IP=192.168.1.162
Set-DenonReceiver -IpAddress 192.168.1.162
Environment=DENON_IP=192.168.1.162
```

After:

```bash
export DENON_IP=192.0.2.10
./denon.sh setip 192.0.2.10
DENON_IP=192.0.2.10
DENON_DEFAULT_IP=192.0.2.10
Set-DenonReceiver -IpAddress 192.0.2.10
Environment=DENON_IP=192.0.2.10
```

Use `192.0.2.0/24` documentation addresses consistently across README, man page, PowerShell docs, service comments, and research templates unless a research artifact intentionally records a sanitized example.

### Add profile cache documentation

Add under Configuration:

```text
If `DENON_PROFILE=<name>` is set, discovery and `denon setip` use
`~/.cache/denon_ip.<name>`. Without `DENON_PROFILE`, the cache remains
`~/.cache/denon_ip`.
```

### Current README sections that are accurate

- Project status and feature overview for the committed v1.2.0-beta.3 tree.
- Bash CLI installation/wrapper guidance, except for the local workspace path.
- Discovery cascade including Avahi/mDNS.
- Data inventory and diagnostics examples.
- Dashboard and HEOS examples.
- PowerShell module overview and limitations.
- MPRIS2 bridge install and behavior, except that it still says the bridge shares `~/.cache/denon_ip`; if profile-scoped cache support is released, clarify whether the daemon remains unprofiled or gains matching profile cache support.
- GitHub readiness and known limitations, with the caveat that private-IP examples should be cleaned or explicitly treated as sanitized documentation placeholders.

## 6. Post-push tasks

After the maintainer has reviewed, committed, and pushed the intended changes:

- [ ] Confirm `git fetch origin && git log --oneline origin/main..HEAD` is empty from a fresh checkout.
- [ ] Update `ARCHITECTURE.md` §7.11 to say the public mirror is now in sync as of the pushed commit and date.
- [ ] Add a §8 Decision Record row for the mirror sync/release hygiene update.
- [ ] Update `VERSION` and RPM spec metadata if preparing a new tag.
- [ ] Run `make srpm` or `make -f .copr/Makefile srpm outdir=/tmp/copr-out`.
- [ ] Run `make tag` only after confirming the intended tag does not already exist.
- [ ] Push the branch and then push the tag manually.
- [ ] Optional: trigger or monitor a COPR build from the new tag.

Suggested manual command outline, for maintainer review only:

```bash
git fetch origin
git status --short
git log --oneline origin/main..HEAD
pytest -q
bash -n denon.sh
zsh -n denon.sh
shellcheck -s bash denon.sh
make -f .copr/Makefile srpm outdir=/tmp/copr-out
# review all output, then decide whether to push/tag
```
