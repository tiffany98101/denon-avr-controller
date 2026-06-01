# RELEASE_PLAN.md

## 1. Divergence audit

Baseline used for this audit:

- Remote fetched: `origin` (`git@github.com:tiffany98101/denon-avr-controller.git`)
- Current branch: `main`
- Release-readiness baseline: post-hardening local branch after the cleanup/security/performance phases
- Fetched public mirror ref at audit time: `origin/main` = `8272a6d feat: improve dashboard-alt renderer layout`
- Result: local `HEAD` is ahead of `origin/main`; review `git log --oneline origin/main..HEAD` before any release push.

### Commits in `origin/main..HEAD`

The hardening/completion commits below are expected in `origin/main..HEAD` after `git fetch origin` unless they have already been pushed. Release-readiness documentation fix commits may appear after these.

| Commit | Summary | Classification | Notes |
|---|---|---|---|
| `a7ac76a` | Add Denon shell completion installer | RELEASE CANDIDATE | Includes user-level bash/zsh/fish completion install flow. |
| `691d6ba` | fix: validate HEOS player ids and detect write failures | RELEASE CANDIDATE | Security/correctness hardening. |
| `1ad3c38` | fix: restore HEOS discovery with pid validation | RELEASE CANDIDATE | Regression fix for HEOS discovery/default behavior. |
| `ff67376` | fix: improve bash portability helpers | RELEASE CANDIDATE | Bash-runtime portability cleanup. |
| `2a5c9d3` | fix: improve mute fallback and probe classification | RELEASE CANDIDATE | Accuracy/reliability cleanup. |
| `23b30cb` | perf: reduce shell helper overhead | RELEASE CANDIDATE | Low-risk helper performance cleanup. |
| `4bf5c58` | security: make AVR TLS verification configurable | RELEASE CANDIDATE | TLS compatibility mode is now explicit and configurable. |

### Files newly present in the public mirror

The public mirror may lag the local release branch. Treat `origin/main..HEAD` as the authoritative review set.

### Dirty working tree not covered by `origin/main..HEAD`

Before tagging or pushing, rerun `git status --short` and account for every
modified or untracked path. A release commit should contain only intentional
documentation, tests, packaging metadata, or code changes.

### Public-safety scan findings

Current committed tree contains some example/private LAN IPs in research and
PowerShell documentation. These are not necessarily secrets, but they should be
cleaned or explicitly waived before the next public release.

- README and man-page user examples should use documentation addresses such as `192.0.2.10`.
- Research artifacts may retain sanitized live-probe addresses if they are intentionally historical.
- `denon-mpris.service`, PowerShell docs, and research docs contain `192.168.1.100` examples.
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
- [ ] `zsh -n completions/zsh/_denon`
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

3. Concurrent write mitigation PR
   - Include `denon.sh`, `ARCHITECTURE.md`, and `tests/test_no_verify_and_locking.py`.
   - Keep MPRIS daemon debounce out of scope, but leave the documented TODO.

4. Version/tag preparation PR
   - Update `VERSION`.
   - Update `rpm/denon-avr-controller.spec` globals and `%changelog`.
   - Update release notes/CHANGELOG for the chosen version.
   - Run SRPM generation locally before tagging.

Why smaller PRs:

- The public mirror already has the big MPRIS/test/RPM/data-family sync, so an umbrella sync PR would mix already-public work with new unreleased behavior.
- The dirty-tree changes have separable risk: cache path behavior, write serialization, and release hygiene.
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
- Bash, zsh, and fish completions plus the `denon completion install` user installer.
- HEOS player IDs are validated as signed decimal IDs before `pid=...` command construction.
- Write commands fail cleanly on rejected/non-2xx `set_config` responses.
- HTTPS/TLS verification is explicit: default AVR-compatible `-k`, with opt-in strict/system trust, custom CA, or pinned public key.
- Fedora RPM/COPR packaging files.
- Per-profile IP cache path: `~/.cache/denon_ip.<profile>` when `DENON_PROFILE` is active.
- Global `--no-verify` flag for batch write operations.
- Optional `DENON_LOCK=1` flock serialization for write commands.

### Architectural changes

- `ARCHITECTURE.md` is now the project-truth contract for future changes.
- §4.3 documents TTL-bounded discovery and profile-scoped cache behavior.
- §4.4 documents layered config and profiles.
- §4.11 documents the nested-function promotion test seam.
- §6.1 documents the MPRIS daemon boundary.
- §6.5 documents Makefile/RPM packaging workflow.
- §7.6 documents write-race mitigations and remaining MPRIS debounce work.

### Breaking changes

- No intentional breaking CLI changes are identified.
- Profile-scoped IP cache is additive for users who set `DENON_PROFILE`; users without `DENON_PROFILE` continue using `~/.cache/denon_ip`.
- `DENON_LOCK=1` is opt-in and default behavior remains lock-free.
- `--no-verify` is opt-in and default behavior remains set-then-verify.

### Upgrade notes

- For CLI-only users, continue using `denon status`, `denon vol`, and existing commands as before.
- For profile users, run `denon setip <ip>` once per active `DENON_PROFILE` if they want warm per-profile caches immediately.
- For MPRIS bridge users, install with `make install-mpris` or the RPM package, then enable the user unit with `systemctl --user enable --now denon-mpris.service`.
- For packaged Fedora/COPR users, ensure the release tag, `VERSION`, and RPM spec version metadata all match before triggering a build.

## 5. README.md delta

Current `README.md` includes the post-hardening user-visible behavior:

- bash runtime versus bash/zsh/fish completion support
- completion installer usage
- `set_config`/write failure behavior
- HEOS signed-decimal player-id validation wording
- TLS compatibility mode and opt-in hardening variables
- documentation-address examples for the main Bash CLI paths

Use `192.0.2.0/24` documentation addresses consistently in user-facing examples
unless a research artifact intentionally records a sanitized historical probe.

### Current README sections that are accurate

- Project status and feature overview for the committed v1.2.0-beta.3 tree.
- Bash CLI installation/wrapper guidance and bash/zsh/fish completion installer guidance.
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
zsh -n completions/zsh/_denon
shellcheck -s bash denon.sh
make -f .copr/Makefile srpm outdir=/tmp/copr-out
# review all output, then decide whether to push/tag
```
