# DenonAvrController PowerShell module

Native PowerShell support for Denon AVR Controller. This module talks directly
to the receiver with PowerShell/.NET HTTP, XML, and TCP socket APIs. It does not
require WSL, Bash, zsh, Git Bash, Cygwin, MSYS, curl, nc, sed, awk, or grep at
runtime.

PowerShell 7+ on Windows is the primary target. Windows PowerShell 5.1 should
work for the core commands where practical.

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

## Configure the receiver

Configuration is stored in memory for the current PowerShell session:

```powershell
Set-DenonReceiver -IpAddress 192.168.1.100
```

Replace `192.168.1.100` with your AVR's local IP address.

Many Denon receivers present a self-signed or otherwise untrusted HTTPS
certificate on port 10443. Certificate validation is enabled by default. If your
receiver fails with a certificate trust error, explicitly allow that receiver's
local certificate with:

```powershell
Set-DenonReceiver -IpAddress 192.168.1.100 -SkipCertificateCheck
```

In PowerShell 7+, `-SkipCertificateCheck` uses PowerShell's per-request
certificate bypass. In Windows PowerShell 5.1, there is no per-request equivalent,
so the module temporarily installs a .NET certificate callback for the duration
of the individual request and restores the previous callback afterward.

You can also set an environment fallback before importing or using the module:

```powershell
$env:DENON_IP = '192.168.1.100'
```

If `DENON_IP` is not set, the module also checks `DENON_DEFAULT_IP`.

## Read-only commands

Start with read-only checks:

```powershell
Test-DenonReceiver
Get-DenonStatus
Get-DenonSources
Get-DenonZone2Status
Get-DenonSleep
Show-DenonDashboard
```

Read-only functions:

- `Test-DenonReceiver`
- `Get-DenonInfo`
- `Get-DenonStatus`
- `Get-DenonSources`
- `Get-DenonZone2Status`
- `Get-DenonSleep`
- `Show-DenonDashboard`

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
```

`Get-DenonSources` returns one object per source with:

```text
Zone, Index, ReceiverName, DisplayName, Active
```

## State-changing commands

These commands change AVR state:

```powershell
Set-DenonMute -On
Set-DenonMute -Off
Step-DenonVolume -Db -1
Set-DenonSource -Name "HEOS Music"
```

Volume commands refuse targets above `-10.0` dB by default. Adjust the session
limit when configuring the receiver, for example
`Set-DenonReceiver -IpAddress 192.168.1.100 -MaxVolumeDb -12.0`, or use
`-AllowAboveMaxVolume` on an individual volume command when you intentionally
need to exceed the guard.

Additional state-changing commands:

- `Set-DenonPower -On`
- `Set-DenonPower -Off`
- `Set-DenonVolume -Db -42`
- `Step-DenonVolume -Db 1`
- `Set-DenonSource -Index 13`
- `Set-DenonZone2Power -On`
- `Set-DenonZone2Power -Off`
- `Set-DenonZone2Mute -On`
- `Set-DenonZone2Mute -Off`
- `Set-DenonZone2Volume -Raw 650`
- `Step-DenonZone2Volume -Db -1`

The state-changing commands support `-WhatIf` through PowerShell's common
parameter behavior.

## Network behavior

This first PowerShell pass prefers explicit IP configuration. It does not
attempt full SSDP discovery.

The HTTP/XML implementation follows the existing Bash CLI behavior reference:

- `get_config type=3` for receiver identity
- `get_config type=4` for power
- `get_config type=7` for source lists and active source index
- `get_config type=12` for volume and mute
- `set_config` for power, source, volume, and mute changes

Known Denon mappings preserved:

- Power `1` means `ON`
- Power `3` means `OFF`
- Mute `1` means muted
- Mute `2` means unmuted
- Raw volume maps to dB as `raw / 10 - 80`

`Get-DenonSleep` uses the native TCP helper because sleep timer status is easier
through the Denon telnet-style command interface.

## Later work

The initial PowerShell module intentionally does not port every Bash feature.
Left for later:

- Full terminal dashboard parity
- Full HEOS browse/search/queue support
- Presets
- Profiles
- Snapshot diff
- `watch-event`
- MQTT/Home Assistant
- UPnP eventing
