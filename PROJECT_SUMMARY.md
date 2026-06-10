# Project Summary: Denon AVR Controller

## Path

`/home/administrator/organized_projects/denon/denon_main`

## What it is

A local-network CLI, dashboard, and PowerShell module for Denon AVR/HEOS control and diagnostics.

## What it does

It controls receiver power, input, volume, mute, sound modes, zones, HEOS playback, dashboard views, snapshots, discovery, diagnostics, shell completions, MPRIS integration, and safe read-only data inventory commands. The Bash CLI is the source-of-truth implementation, with a native PowerShell module tracking the command surface.

## Stack

- Language(s): Bash, Python, PowerShell, Markdown
- Frameworks/libraries: curl/nc/avahi-style local network tools, pytest, optional PowerShell/Pester/PSScriptAnalyzer
- Packaging/build system: Makefile, RPM spec, shell install snippets
- Runtime/services: local CLI scripts, optional MPRIS/systemd service, local receiver HTTP/telnet/HEOS access

## How to run

```bash
./denon.sh doctor
./denon.sh status
./denon.sh dashboard
pytest -q
make test
```

## Current status

Active. Git branch is `main`; recent commits include PowerShell parity and dashboard/version hardening. The worktree has untracked `.claude/` and `Screenshot_20260601_174824.png`.

## Obvious next steps or TODOs

Keep Bash and PowerShell behavior aligned. Continue validating receiver-facing commands against real hardware. Review local screenshots/handoff files before committing.

## Warnings / unclear areas

This tool sends commands to real local-network AV hardware. Some diagnostics are read-only, but control commands can change receiver state. Local cache/config paths and screenshots may reveal device/network details.

