#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

$moduleRoot = Split-Path -Parent $PSCommandPath
$manifestPath = Join-Path $moduleRoot 'DenonAvrController.psd1'

$manifest = Test-ModuleManifest $manifestPath
Assert-True ($manifest.Name -eq 'DenonAvrController') 'manifest name mismatch'
Assert-True ($manifest.PowerShellVersion.ToString() -eq '7.0') 'PowerShellVersion should be 7.0'

$moduleSource = Get-Content -LiteralPath (Join-Path $moduleRoot 'DenonAvrController.psm1') -Raw
Assert-True ($moduleSource -match 'HttpClientHandler') 'custom TLS validation should use HttpClientHandler'
Assert-True ($moduleSource -match 'DenonAvrController\.PowerShell\.TlsValidator') 'custom TLS validation should use the compiled validator'
Assert-True ($moduleSource -notmatch 'ServerCertificateCustomValidationCallback\s*=\s*\{') 'custom TLS validation must not use a PowerShell scriptblock callback'
Assert-True ($moduleSource -notmatch 'ServicePointManager') 'custom TLS validation must not use ServicePointManager on PowerShell 7'

Import-Module $manifestPath -Force
$commands = @(Get-Command -Module DenonAvrController | Select-Object -ExpandProperty Name)
foreach ($name in @(
        'Invoke-DenonCommand',
        'Find-DenonReceiver',
        'Get-DenonRawConfig',
        'Get-DenonDataDump',
        'Invoke-DenonDataDiscover',
        'Invoke-DenonHeos',
        'Invoke-DenonListeningPreset',
        'Watch-DenonEvent',
        'Set-DenonSoundMode',
        'Invoke-DenonQuickSelect',
        'Get-DenonConfig',
        'Get-DenonCompletionCommandSurface'
    )) {
    Assert-True ($commands -contains $name) "missing exported command: $name"
}
Assert-True (-not ($commands -contains 'ConvertTo-DenonMuteBoolean')) 'private helper was exported'

$surface = Get-DenonCompletionCommandSurface
foreach ($name in @(
        'info', 'data', 'status', 'signal-debug', 'rawstatus', 'raw', 'snapshot',
        'diff', 'dashboard', 'dashboard-alt', 'sources', 'source', 'rename-source',
        'source-names', 'clear-source-name', 'sleep', 'qs', 'quick', 'quick-select',
        'on', 'off', 'xbox', 'xfinity', 'bluray', 'tv', 'phono', 'heos', 'vol',
        'up', 'down', 'mute', 'unmute', 'toggle', 'movie', 'game', 'night',
        'music', 'mode', 'dyn-eq', 'dyn-vol', 'cinema-eq', 'multeq', 'bass',
        'treble', 'play', 'pause', 'stop', 'next', 'prev', 'previous', 'track',
        'now', 'zone2', 'watch-event', 'preset', 'discover', 'doctor', 'setip',
        'config', 'profile', 'completion', 'version', 'help'
    )) {
    Assert-True ($surface.Commands -contains $name) "missing command surface entry: $name"
}
foreach ($name in @('queue', 'groups', 'group', 'browse', 'search', 'play-stream', 'repeat', 'shuffle', 'update')) {
    Assert-True ($surface.HeosCommands -contains $name) "missing HEOS surface entry: $name"
}

$oldConfig = [Environment]::GetEnvironmentVariable('DENON_CONFIG')
$oldAliases = [Environment]::GetEnvironmentVariable('DENON_SOURCE_ALIASES')
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    [Environment]::SetEnvironmentVariable('DENON_CONFIG', (Join-Path $tempRoot 'config'), 'Process')
    [Environment]::SetEnvironmentVariable('DENON_SOURCE_ALIASES', (Join-Path $tempRoot 'source_aliases'), 'Process')

    $set = Set-DenonConfig -Key DENON_DEFAULT_IP -Value 192.0.2.55
    Assert-True ((Get-Content -LiteralPath $set.Path -Raw) -match 'DENON_DEFAULT_IP=192.0.2.55') 'config file did not contain written value'
    $read = Get-DenonConfig -Key DENON_DEFAULT_IP
    Assert-True ($read.Value -eq '192.0.2.55') 'config readback failed'
    $removed = Remove-DenonConfig -Key DENON_DEFAULT_IP
    Assert-True $removed.Removed 'config removal did not report success'
}
finally {
    [Environment]::SetEnvironmentVariable('DENON_CONFIG', $oldConfig, 'Process')
    [Environment]::SetEnvironmentVariable('DENON_SOURCE_ALIASES', $oldAliases, 'Process')
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'DenonAvrController validation passed'
