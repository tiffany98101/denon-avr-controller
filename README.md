# denon

A practical shell-based controller for modern Denon AVRs on a home LAN.

It wraps the receiver's HTTPS config API and legacy transport controls into simple commands for status, source switching, volume, mute, Zone 2, snapshots, raw API access, and quick troubleshooting.

## What it does

- Discovers a compatible Denon AVR on your LAN
- Reads main-zone and Zone 2 status
- Switches sources by index or friendly name
- Controls power, mute, and volume
- Sends common media and sound mode commands
- Supports local source aliases without changing the AVR itself
- Dumps raw XML endpoints for debugging
- Saves snapshots of core receiver state
- Includes `doctor` checks for dependencies and reachability
- Works when run directly or when sourced into Bash or Zsh

## Run it now

```bash
chmod +x denon_release_candidate.sh denon_automated_test.sh
./denon_release_candidate.sh doctor
./denon_release_candidate.sh status
```

## Tested

Tested on Ubuntu against a **Denon AVR-X1600H**.

Validated coverage includes:

* `status`
* `info --json`
* raw reads
* snapshots
* mute / unmute
* volume up / down
* main-zone source switching
* Zone 2 power / source control
* sound mode changes
* media transport commands
* Bash and Zsh loading / execution

Manual interactive validation was done in Zsh. Shell execution and test harness coverage were also validated from Bash.

## Requirements

Common Linux tools:

* `bash`
* `curl`
* `awk`
* `sed`
* `grep`
* `ip`
* `nc` (netcat)

Optional but useful:

* `jq`
* `shellcheck`

Ubuntu install example:

```bash
sudo apt update
sudo apt install -y curl gawk sed grep iproute2 netcat-openbsd jq shellcheck
```

## Install

Clone the repo and make the scripts executable:

```bash
git clone https://github.com/tiffany98101/denon-avr-controller.git
cd denon-avr-controller
chmod +x denon_release_candidate.sh denon_automated_test.sh
```

Run it directly:

```bash
./denon_release_candidate.sh status
```

Or source it into your shell so you can use `denon ...` as a command.

### Bash

```bash
echo 'source /full/path/to/denon_release_candidate.sh' >> ~/.bashrc
source ~/.bashrc
```

### Zsh

```bash
echo 'source /full/path/to/denon_release_candidate.sh' >> ~/.zshrc
source ~/.zshrc
```

## Quick start

Use `./denon_release_candidate.sh ...` if you are running the script directly.

Examples later in this README that use `denon ...` assume you have already sourced the script into your shell.

Check dependencies and receiver reachability:

```bash
./denon_release_candidate.sh doctor
```

Show current status:

```bash
./denon_release_candidate.sh status
./denon_release_candidate.sh info --json
```

List sources:

```bash
./denon_release_candidate.sh sources
./denon_release_candidate.sh sources 2
```

Switch source:

```bash
./denon_release_candidate.sh source tv
./denon_release_candidate.sh source heos
```

Adjust volume and mute:

```bash
./denon_release_candidate.sh vol
./denon_release_candidate.sh vol -35
./denon_release_candidate.sh up 1
./denon_release_candidate.sh down 1
./denon_release_candidate.sh mute
./denon_release_candidate.sh unmute
```

Use Zone 2:

```bash
./denon_release_candidate.sh zone2 status
./denon_release_candidate.sh zone2 on
./denon_release_candidate.sh zone2 source 10
./denon_release_candidate.sh zone2 off
```

Use raw API and snapshots:

```bash
./denon_release_candidate.sh raw get 3
./denon_release_candidate.sh raw get 7
./denon_release_candidate.sh raw set 12 '<MainZone><Mute>1</Mute></MainZone>'
./denon_release_candidate.sh snapshot
```

## Command summary

### Receiver status

```bash
denon info
denon info --json
denon status
denon status --json
denon rawstatus
denon raw get <type>
denon raw set <type> '<xml>'
denon snapshot [dir]
denon doctor
```

### Sources

```bash
denon sources
denon sources 2
denon source <id|name>
```

### Local source display names

```bash
denon rename-source <id|name> "<new name>"
denon source-names
denon clear-source-name <id|name>
```

### Power and mute

```bash
denon on
denon off
denon mute
denon unmute
```

### Volume

```bash
denon vol
denon vol -35
denon vol +2
denon up [dB]
denon down [dB]
```

### Quick source shortcuts

```bash
denon xfinity
denon bluray
denon xbox
denon tv
denon phono
denon heos
```

### Presets

```bash
denon movie
denon game
denon night
denon music
```

### Sound mode and media

```bash
denon mode <mode>
denon play
denon pause
denon next
denon prev
denon track
denon now
```

### Zone 2

```bash
denon zone2 status
denon zone2 sources
denon zone2 source <id|name>
denon zone2 rename-source <id|name> "<new name>"
denon zone2 clear-source-name <id|name>
denon zone2 on
denon zone2 off
denon zone2 vol <raw>
```

### Discovery and setup

```bash
denon discover
denon setip <ip>
```

## Automated test script

The repo includes `denon_automated_test.sh` for repeatable checks.

Run the safe pass:

```bash
./denon_automated_test.sh --script ./denon_release_candidate.sh
```

Run the destructive/state-changing pass only when nobody is using the receiver:

```bash
./denon_automated_test.sh --script ./denon_release_candidate.sh --destructive
```

Suggested manual checks before public release:

* `bash -n denon_release_candidate.sh`
* `shellcheck -s bash denon_release_candidate.sh`
* `bash ./denon_release_candidate.sh --help`
* `zsh -lc 'source ./denon_release_candidate.sh; whence denon; denon status'`

## Environment variables

These are supported by the script:

```bash
DENON_IP
DENON_DEFAULT_IP
DENON_SCAN_LAN=1
DENON_MAX_VOLUME_DB
DENON_VOLUME_STEP_DB
DENON_SOURCE_ALIASES
DENON_CURL_CONNECT_TIMEOUT
DENON_CURL_MAX_TIME
DENON_SSDP_TIMEOUT
DENON_SSDP_MX
DENON_DEBUG=1
```

Examples:

Pin the receiver IP:

```bash
export DENON_IP=192.168.1.162
```

Enable verbose logging:

```bash
export DENON_DEBUG=1
```

Increase request timeout if source changes are slow:

```bash
export DENON_CURL_MAX_TIME=10
```

## Source aliases

Aliases are local only. They do **not** rename sources inside the AVR.

Example:

```bash
denon rename-source tv "Living Room TV"
denon sources
denon source "Living Room TV"
denon clear-source-name "Living Room TV"
```

## Safety notes

This script is intended for use on a **trusted local network**.

It talks to the receiver over local control endpoints and may use HTTPS with self-signed or device-local certificate behavior typical of consumer AV equipment. Do not treat it like a hardened remote-management tool for hostile networks.

Before running state-changing commands:

* Be careful with volume commands
* Be careful with Zone 2 power and source changes
* Be careful with raw `set` commands
* Volume commands use the AVR's dB-style control model internally. Test with small adjustments first, especially if your receiver UI is configured to show a different volume scale.
* Do not run destructive or disruptive tests while someone is using the receiver

## Troubleshooting

Run the built-in checks first:

```bash
denon doctor
```

If discovery is noisy or unreliable, set the IP manually:

```bash
export DENON_IP=192.168.1.162
denon status
```

If source switching or writes time out on a slow response, try:

```bash
export DENON_CURL_MAX_TIME=10
```

If you want to see request/debug flow:

```bash
DENON_DEBUG=1 denon status
```

Basic shell checks:

```bash
bash -n denon_release_candidate.sh
shellcheck -s bash denon_release_candidate.sh
```

## Bash and Zsh notes

This is a **Bash-oriented** script that can also be sourced and used comfortably from Zsh.

It is **not** a POSIX `sh` script.

## Known limits

* Tested on Ubuntu with a Denon AVR-X1600H
* Intended for trusted local-network use
* Bash-oriented; usable from Zsh when sourced
* Not a POSIX `sh` script
* Behavior may vary across receiver models and firmware versions

## Example session

```bash
denon doctor
denon status
denon sources
denon source heos
denon status
denon vol -35
denon mute
denon unmute
denon zone2 status
denon snapshot
```

## Why this exists

Denon receivers expose useful LAN control interfaces, but the raw API is awkward to use by hand. This script is meant to be a practical operator tool for real home-network use, testing, debugging, and light reverse-engineering.

## Disclaimer

This project is an independent tool and is not affiliated with, authorized by, or endorsed by Denon or Masimo Consumer. Use it at your own risk.

## License

MIT
