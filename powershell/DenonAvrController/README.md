# DenonAvrController PowerShell module

Native PowerShell support for Denon AVR Controller. This module talks directly
to the receiver with PowerShell/.NET HTTP, XML, and TCP socket APIs. It does not
require WSL, Bash, zsh, Git Bash, Cygwin, MSYS, curl, nc, sed, awk, or grep at
runtime.

PowerShell 7+ is the supported target on Linux, macOS, and Windows.

## Install PowerShell 7

Install PowerShell 7 from Microsoft:

```powershell
winget install Microsoft.PowerShell
```

Or download it from:

```text
https://github.com/PowerShell/PowerShell/releases
```

## Import the module

From the repository root:

```powershell
Import-Module .\powershell\DenonAvrController\DenonAvrController.psd1
```

Validate the manifest and exported commands:

```powershell
Test-ModuleManifest .\powershell\DenonAvrController\DenonAvrController.psd1
Import-Module .\powershell\DenonAvrController\DenonAvrController.psd1 -Force
Get-Command -Module DenonAvrController
```

## Configure the receiver

Configuration can be stored in memory for the current PowerShell session:

```powershell
Set-DenonReceiver -IpAddress 192.168.1.100
```

Replace `192.168.1.100` with your AVR's local IP address.

To persist the receiver IP in the shared Denon cache:

```powershell
Set-DenonReceiverIp 192.168.1.100
```

The module resolves the receiver in this order:

1. `Set-DenonReceiver` session state.
2. `DENON_IP`.
3. Cached IP from `Set-DenonReceiverIp` or discovery.
4. `DENON_DEFAULT_IP`.
5. SSDP when using `Find-DenonReceiver -RefreshCache`.

Many Denon receivers present a self-signed or otherwise untrusted HTTPS
certificate on port 10443. Like the Bash CLI, the module defaults to
receiver-compatible certificate handling. To require system trust, set
`DENON_CURL_INSECURE=0`. To explicitly allow an untrusted receiver certificate
for the current session:

```powershell
Set-DenonReceiver -IpAddress 192.168.1.100 -SkipCertificateCheck
```

In PowerShell 7+, `-SkipCertificateCheck` uses PowerShell's per-request
certificate bypass. `DENON_CURL_CACERT` and `DENON_CURL_PINNEDPUBKEY` use a
compiled per-request .NET `HttpClientHandler` validation callback, not a
process-global certificate callback or a PowerShell scriptblock callback.
PowerShell supports `DENON_CURL_PINNEDPUBKEY` values in the
`sha256//BASE64HASH` form.

You can also set an environment fallback before importing or using the module:

```powershell
$env:DENON_IP = '192.168.1.100'
```

The module also reads the Bash-compatible config file. Use these helpers:

```powershell
Get-DenonConfig
Set-DenonConfig -Key DENON_DEFAULT_IP -Value 192.168.1.100
Remove-DenonConfig -Key DENON_DEFAULT_IP
Get-DenonProfile
Set-DenonProfile -Name living-room -Key DENON_DEFAULT_IP -Value 192.168.1.100
```

## Read-only commands

Start with read-only checks:

```powershell
Test-DenonReceiver
Get-DenonStatus
Get-DenonReceiverSummary
Get-DenonNowPlaying
Get-DenonSources
Get-DenonZone2Status
Get-DenonSleep
Show-DenonDashboard
Get-DenonDataSummary
Get-DenonDataFields
Get-DenonDataDump
Get-DenonRawStatus
```

Read-only functions:

- `Test-DenonReceiver`
- `Get-DenonInfo`
- `Get-DenonStatus`
- `Get-DenonReceiverSummary`
- `Get-DenonNowPlaying`
- `Get-DenonSources`
- `Get-DenonZone2Status`
- `Get-DenonSleep`
- `Show-DenonDashboard`
- `Get-DenonRawConfig`
- `Get-DenonRawStatus`
- `Get-DenonDataFields`
- `Get-DenonDataSummary`
- `Get-DenonDataDump`
- `Get-DenonDataCapabilities`

`Get-DenonStatus` returns a structured object:

```powershell
Get-DenonStatus
```

Example shape:

```text
IpAddress   : 192.168.1.100
Power       : ON
SourceIndex : 13
SourceName  : HEOS Music
VolumeDb    : -42
Muted       : False
MuteRaw     : MUOFF
MuteXmlRaw  : 1
```

`Muted` is nullable. `$true` means mute ON, `$false` means mute OFF, and `$null`
means the receiver did not return a clear mute value. Current builds normalize
HTTP/XML values such as `1`/`2`, text values such as `on`/`off`, and telnet
values such as `MUON`/`MUOFF`. For main-zone status, a clear telnet `MU?`
response is preferred over the type-12 XML mute field because some receivers can
report stale or ambiguous XML mute values while HEOS audio is playing.

`Get-DenonSources` returns one object per source with:

```text
Zone, Index, ReceiverName, DisplayName, Active
```

`Get-DenonReceiverSummary` and `Get-DenonDataSummary` return compact diagnostics
objects with receiver, volume, system, now-playing, firmware-note, and
tool-version sections. `Get-DenonDataDump`, `Get-DenonDataFields`,
`Get-DenonDataCapabilities`, and `Invoke-DenonDataDiscover` cover the safe
read-only data inventory paths used by the Bash CLI.

## State-changing commands

These commands change AVR state:

```powershell
Set-DenonMute -On
Set-DenonMute -Off
Step-DenonVolume -Decibel -1
Set-DenonSource -Name "HEOS Music"
Set-DenonZone2Source -Name "Phono"
```

Volume commands refuse targets above `-10.0` dB by default. Adjust the session
limit when configuring the receiver, for example
`Set-DenonReceiver -IpAddress 192.168.1.100 -MaxVolumeDb -12.0`, or use
`-AllowAboveMaxVolume` on an individual volume command when you intentionally
need to exceed the guard.

Additional state-changing commands:

- `Set-DenonPower -On`
- `Set-DenonPower -Off`
- `Set-DenonVolume -Decibel -42`
- `Step-DenonVolume -Decibel 1`
- `Set-DenonSource -Index 13`
- `Set-DenonZone2Source -Name "Phono"`
- `Set-DenonZone2Power -On`
- `Set-DenonZone2Power -Off`
- `Set-DenonZone2Mute -On`
- `Set-DenonZone2Mute -Off`
- `Set-DenonZone2Volume -Raw 650`
- `Step-DenonZone2Volume -Decibel -1`
- `Set-DenonSleep -Value 30`
- `Invoke-DenonQuickSelect -Number 1`
- `Set-DenonSoundMode -Mode movie`
- `Set-DenonDynamicEq -State on`
- `Set-DenonDynamicVolume -Level light`
- `Set-DenonCinemaEq -State off`
- `Set-DenonMultEq -Mode reference`
- `Set-DenonTone -Control bass -Value 2`
- `Invoke-DenonTransport -Action play`
- `Invoke-DenonHeos queue`
- `Invoke-DenonListeningPreset -Name movie`

The state-changing commands support `-WhatIf` through PowerShell's common
parameter behavior.

## Network behavior

The receiver must be reachable on the same local network as the PowerShell host.
`Find-DenonReceiver -RefreshCache` checks configured IPs and then sends an SSDP
M-SEARCH probe. Avahi/mDNS and LAN ARP scanning remain Bash-specific discovery
paths.

The HTTP/XML implementation follows the existing Bash CLI behavior reference:

- `get_config type=3` for receiver identity
- `get_config type=1`, `5`, `6`, `8`, `9`, `10`, and `11` for optional diagnostics
- `get_config type=4` for power
- `get_config type=7` for source lists and active source index
- `get_config type=12` for volume and mute
- `set_config` for power, source, volume, and mute changes

Known Denon mappings preserved:

- Power `1` means `ON`
- Power `3` means `OFF`
- Mute `1` means muted
- Mute `2` means unmuted
- Telnet `MUON` / `Z2MUON` means muted
- Telnet `MUOFF` / `Z2MUOFF` means unmuted
- Raw volume maps to dB as `raw / 10 - 80`

`Get-DenonSleep` uses the native TCP helper because sleep timer status is easier
through the Denon telnet-style command interface.
`Get-DenonNowPlaying` uses the receiver's network-audio XML endpoint and, when
available, the HEOS CLI read-only player status commands.

## Bash-style migration shim

`Invoke-DenonCommand` accepts Bash-style command names and dispatches to native
PowerShell functions:

```powershell
Invoke-DenonCommand status
Invoke-DenonCommand source heos
Invoke-DenonCommand heos queue
Invoke-DenonCommand data fields --all
Invoke-DenonCommand data discover
Invoke-DenonCommand raw get 3
Invoke-DenonCommand config set DENON_DEFAULT_IP 192.168.1.100
```

The shim is intended for migration and parity checks. Idiomatic scripts should
prefer the named PowerShell functions.

## Completion

PowerShell completion metadata is available through:

```powershell
Get-DenonCompletionCommandSurface
Register-DenonArgumentCompleter
```

The Bash CLI still generates bash, zsh, and fish completion files with
`denon completion bash|zsh|fish|install`.

## Validation

The repository includes both Pester tests and a no-dependency validation script:

```powershell
Invoke-Pester ./powershell/DenonAvrController/DenonAvrController.Tests.ps1
./powershell/DenonAvrController/Test-DenonAvrController.ps1
```

## Remaining shell-specific gaps

- Bash/zsh/fish completion file generation remains owned by `denon.sh`; the
  module exposes completion metadata for native PowerShell use.
- `dashboard-alt` remains the experimental Python preview and is not
  reimplemented by this PowerShell module.
