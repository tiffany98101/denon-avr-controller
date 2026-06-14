# Project Summary: Denon AVR Controller

## Path

`/home/administrator/organized_projects/denon/denon_main`

## What it is

A local-network CLI, dashboard, and PowerShell module for Denon AVR/HEOS control and diagnostics.

## What it does

It controls receiver power, input, volume, mute, sound modes, zones, HEOS playback, dashboard views, snapshots, discovery, diagnostics, shell completions, MPRIS integration, and safe read-only data inventory commands. The Bash CLI is the source-of-truth implementation, with a native PowerShell module tracking the command surface. The current branch also includes the v2 Bash `lib/` transport/protocol/config/compat layer and an alternate `dashboard-ultra` shell dashboard for ultrawide terminals.

## Stack

- Language(s): Bash, Python, PowerShell, Markdown
- Frameworks/libraries: curl/nc/ncat/avahi-style local network tools, jq for v2 JSON config helpers, pytest, bats, optional PowerShell/Pester/PSScriptAnalyzer
- Packaging/build system: Makefile, RPM spec, shell install snippets
- Runtime/services: local CLI scripts, optional MPRIS/systemd service, local receiver HTTP/telnet/HEOS access

## How to run

```bash
./denon.sh doctor
./denon.sh status
./denon.sh dashboard
./denon.sh dashboard-ultra --watch --interval 5
./test/run
pytest -q
make test
```

## Current status

Active. Current review branch is `v2-impl`; recent commits include the v2 Bash library layer, dashboard-ultra AppCommand/keybinding fixes, and RPM release/runtime-layout updates. Generated artifact directories such as `dist/` and `rpmbuild-review-*/` should stay out of narrow docs/code reviews unless the task explicitly targets build outputs.

## Obvious next steps or TODOs

Keep Bash and PowerShell behavior aligned. Continue validating receiver-facing commands against real hardware. For dashboard-ultra, keep AppCommand batches at five verbs or fewer; AVR-X1600H validation showed six verbs returns `<error>1</error>` and seven or more can wedge `:8080` for about 51 seconds.

## Warnings / unclear areas

This tool sends commands to real local-network AV hardware. Some diagnostics are read-only, but control commands can change receiver state. Local cache/config paths and screenshots may reveal device/network details.
