$script:ModuleRoot = Split-Path -Parent $PSCommandPath
$script:ManifestPath = Join-Path $script:ModuleRoot 'DenonAvrController.psd1'
Import-Module $script:ManifestPath -Force

BeforeAll {
    $script:ModuleRoot = $PSScriptRoot
    $script:ManifestPath = Join-Path $script:ModuleRoot 'DenonAvrController.psd1'
    Import-Module $script:ManifestPath -Force
}

Describe 'DenonAvrController manifest and exports' {
    It 'has a valid manifest' {
        $manifest = Test-ModuleManifest $script:ManifestPath
        $manifest.Name | Should -Be 'DenonAvrController'
        $manifest.Version.ToString() | Should -Be '1.2.0'
        $manifest.RootModule | Should -Be 'DenonAvrController.psm1'
        $manifest.PowerShellVersion.ToString() | Should -Be '7.0'
    }

    It 'exports public commands and hides private helpers' {
        $commands = @(Get-Command -Module DenonAvrController)
        $commands.Name | Should -Contain 'Get-DenonStatus'
        $commands.Name | Should -Contain 'Invoke-DenonCommand'
        $commands.Name | Should -Contain 'Find-DenonReceiver'
        $commands.Name | Should -Contain 'Get-DenonRawConfig'
        $commands.Name | Should -Contain 'Get-DenonDataDump'
        $commands.Name | Should -Contain 'Invoke-DenonDataDiscover'
        $commands.Name | Should -Contain 'Invoke-DenonHeos'
        $commands.Name | Should -Contain 'Invoke-DenonListeningPreset'
        $commands.Name | Should -Contain 'Watch-DenonEvent'
        $commands.Name | Should -Contain 'Set-DenonSoundMode'
        $commands.Name | Should -Contain 'Invoke-DenonQuickSelect'
        $commands.Name | Should -Contain 'Get-DenonConfig'
        $commands.Name | Should -Contain 'Get-DenonCompletionCommandSurface'
        $commands.Name | Should -Contain 'Get-DenonReceiverSummary'
        $commands.Name | Should -Contain 'Get-DenonNowPlaying'
        $commands.Name | Should -Not -Contain 'ConvertTo-DenonMuteBoolean'
        $commands.Name | Should -Not -Contain 'Get-DenonStatusFromXml'
    }
}

Describe 'PowerShell parity command surface' {
    InModuleScope DenonAvrController {
        It 'tracks the Bash top-level command set' {
            $surface = Get-DenonCompletionCommandSurface
            foreach ($name in @(
                    'info', 'data', 'status', 'signal-debug', 'rawstatus', 'raw',
                    'snapshot', 'diff', 'dashboard', 'dashboard-alt', 'sources',
                    'source', 'rename-source', 'source-names', 'clear-source-name',
                    'sleep', 'qs', 'quick', 'quick-select', 'on', 'off', 'xbox',
                    'xfinity', 'bluray', 'tv', 'phono', 'heos', 'vol', 'up', 'down',
                    'mute', 'unmute', 'toggle', 'movie', 'game', 'night', 'music',
                    'mode', 'dyn-eq', 'dyn-vol', 'cinema-eq', 'multeq', 'bass',
                    'treble', 'play', 'pause', 'stop', 'next', 'prev', 'previous',
                    'track', 'now', 'zone2', 'watch-event', 'preset', 'discover',
                    'doctor', 'setip', 'config', 'profile', 'completion', 'version',
                    'help'
                )) {
                $surface.Commands | Should -Contain $name
            }
        }

        It 'tracks the HEOS helper subcommands' {
            $surface = Get-DenonCompletionCommandSurface
            foreach ($name in @('now', 'play', 'pause', 'stop', 'next', 'prev', 'queue', 'groups', 'group', 'browse', 'search', 'play-stream', 'repeat', 'shuffle', 'update')) {
                $surface.HeosCommands | Should -Contain $name
            }
        }
    }
}

Describe 'Denon mute normalization' {
    InModuleScope DenonAvrController {
        It 'normalizes ON-like values to true' {
            foreach ($value in @('on', 'ON', 'yes', 'YES', 'true', 'TRUE', '1', 'MUON', 'Z2MUON')) {
                ConvertTo-DenonMuteBoolean -Code $value | Should -BeTrue
            }
        }

        It 'normalizes OFF-like values to false' {
            foreach ($value in @('off', 'OFF', 'no', 'NO', 'false', 'FALSE', '0', '2', 'MUOFF', 'Z2MUOFF')) {
                ConvertTo-DenonMuteBoolean -Code $value | Should -BeFalse
            }
        }

        It 'normalizes unknown values to null' {
            foreach ($value in @('', 'unknown', 'Unknown', $null, 'bogus')) {
                ConvertTo-DenonMuteBoolean -Code $value | Should -BeNullOrEmpty
            }
        }

        It 'prefers clear telnet mute over XML mute for main zone' {
            Mock Get-DenonTelnetResponseLine { 'MUOFF' }
            Get-DenonMuteCode -XmlCode '1' -Zone Main -PreferTelnet | Should -Be 'MUOFF'
        }

        It 'falls back to XML mute when telnet mute is unavailable' {
            Mock Get-DenonTelnetResponseLine { $null }
            Get-DenonMuteCode -XmlCode '2' -Zone Main -PreferTelnet | Should -Be '2'
        }
    }
}

Describe 'Denon HEOS player id validation' {
    InModuleScope DenonAvrController {
        It 'accepts signed decimal HEOS player ids' {
            foreach ($value in @('1', '0', '-1', '12345')) {
                Test-DenonHeosPlayerId -PlayerId $value | Should -BeTrue
            }
        }

        It 'rejects empty or protocol-injection HEOS player ids' {
            foreach ($value in @('', $null, '1&state=play', "1`r`nheos://player/play_next", 'abc', '1,2')) {
                Test-DenonHeosPlayerId -PlayerId $value | Should -BeFalse
            }
        }
    }
}

Describe 'Denon XML status parsing' {
    InModuleScope DenonAvrController {
        It 'handles missing mute fields as unknown' {
            Mock Get-DenonMuteCode { $XmlCode } -Verifiable
            $receiver = [pscustomobject]@{ IpAddress = '192.0.2.10' }
            $powerXml = [xml]'<listGlobals><MainZone><Power>1</Power></MainZone></listGlobals>'
            $sourceXml = [xml]'<SourceList><Zone zone="1" index="13"><Source index="13"><Name>HEOS Music</Name></Source></Zone></SourceList>'
            $volumeXml = [xml]'<listGlobals><MainZone><Volume>450</Volume></MainZone></listGlobals>'

            $status = Get-DenonStatusFromXml -Receiver $receiver -PowerXml $powerXml -SourceXml $sourceXml -VolumeXml $volumeXml
            $status.Muted | Should -BeNullOrEmpty
            $status.SourceName | Should -Be 'HEOS Music'
        }

        It 'does not report muted when telnet says MUOFF' {
            Mock Get-DenonMuteCode { 'MUOFF' } -Verifiable
            $receiver = [pscustomobject]@{ IpAddress = '192.0.2.10' }
            $powerXml = [xml]'<listGlobals><MainZone><Power>1</Power></MainZone></listGlobals>'
            $sourceXml = [xml]'<SourceList><Zone zone="1" index="13"><Source index="13"><Name>HEOS Music</Name></Source></Zone></SourceList>'
            $volumeXml = [xml]'<listGlobals><MainZone><Volume>450</Volume><Mute>1</Mute></MainZone></listGlobals>'

            $status = Get-DenonStatusFromXml -Receiver $receiver -PowerXml $powerXml -SourceXml $sourceXml -VolumeXml $volumeXml
            $status.Muted | Should -BeFalse
            $status.MuteRaw | Should -Be 'MUOFF'
        }

        It 'keeps Zone 2 mute OFF behavior' {
            Mock Get-DenonMuteCode { 'Z2MUOFF' } -Verifiable
            $receiver = [pscustomobject]@{ IpAddress = '192.0.2.10' }
            $powerXml = [xml]'<listGlobals><Zone2><Power>3</Power></Zone2></listGlobals>'
            $sourceXml = [xml]'<SourceList><Zone zone="2" index="10"><Source index="10"><Name>Phono</Name></Source></Zone></SourceList>'
            $volumeXml = [xml]'<listGlobals><Zone2><Volume>650</Volume><Mute>2</Mute></Zone2></listGlobals>'

            $status = Get-DenonZone2StatusFromXml -Receiver $receiver -PowerXml $powerXml -SourceXml $sourceXml -VolumeXml $volumeXml
            $status.Muted | Should -BeFalse
            $status.SourceName | Should -Be 'Phono'
        }
    }
}

Describe 'Denon PowerShell config and alias parity' {
    BeforeEach {
        $script:OldDenonConfig = [Environment]::GetEnvironmentVariable('DENON_CONFIG')
        $script:OldDenonAliases = [Environment]::GetEnvironmentVariable('DENON_SOURCE_ALIASES')
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        [Environment]::SetEnvironmentVariable('DENON_CONFIG', (Join-Path $script:TempRoot 'config'), 'Process')
        [Environment]::SetEnvironmentVariable('DENON_SOURCE_ALIASES', (Join-Path $script:TempRoot 'source_aliases'), 'Process')
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable('DENON_CONFIG', $script:OldDenonConfig, 'Process')
        [Environment]::SetEnvironmentVariable('DENON_SOURCE_ALIASES', $script:OldDenonAliases, 'Process')
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    InModuleScope DenonAvrController {
        It 'writes and removes Bash-compatible config key files' {
            $set = Set-DenonConfig -Key DENON_DEFAULT_IP -Value 192.0.2.55
            $set.Path | Should -Be ([Environment]::GetEnvironmentVariable('DENON_CONFIG'))
            Get-Content -LiteralPath $set.Path -Raw | Should -Match 'DENON_DEFAULT_IP=192.0.2.55'

            $config = Get-DenonConfig -Key DENON_DEFAULT_IP
            $config.Value | Should -Be '192.0.2.55'

            $removed = Remove-DenonConfig -Key DENON_DEFAULT_IP
            $removed.Removed | Should -BeTrue
            Get-Content -LiteralPath $set.Path -Raw | Should -Not -Match 'DENON_DEFAULT_IP='
        }

        It 'applies source display aliases using the Bash tab-separated file format' {
            Set-Content -LiteralPath ([Environment]::GetEnvironmentVariable('DENON_SOURCE_ALIASES')) -Value "1`t13`tLiving Room HEOS" -Encoding utf8
            $sourceXml = [xml]'<SourceList><Zone zone="1" index="13"><Source index="13"><Name>HEOS Music</Name></Source></Zone></SourceList>'

            $source = Get-DenonSourceRowsFromXml -SourceXml $sourceXml -Zone 1
            $source.ReceiverName | Should -Be 'HEOS Music'
            $source.DisplayName | Should -Be 'Living Room HEOS'
        }
    }
}

Describe 'Denon PowerShell command payload parity' {
    InModuleScope DenonAvrController {
        BeforeEach {
            $script:DenonReceiverConfig.IpAddress = '192.0.2.10'
            $script:DenonReceiverConfig.SkipCertificateCheck = $true
            $script:LastTelnetCommand = $null
            $script:TelnetCommands = @()
            $script:LastSetType = $null
            $script:LastSetData = $null
        }

        It 'maps sound mode to the same telnet code as Bash' {
            Mock Invoke-DenonTelnetCommand { $script:LastTelnetCommand = $Command; [pscustomobject]@{ Sent = $true } }
            Set-DenonSoundMode -Mode pure
            $script:LastTelnetCommand | Should -Be 'MSPURE DIRECT'
        }

        It 'maps sleep timers to zero-padded Denon telnet commands' {
            Mock Invoke-DenonTelnetCommand { $script:TelnetCommands += $Command; [pscustomobject]@{ Sent = $true; ReceivedResponse = $true; Response = "SLP030`r" } }
            Set-DenonSleep -Value 30
            $script:TelnetCommands[0] | Should -Be 'SLP030'
            $script:TelnetCommands[1] | Should -Be 'SLP?'
        }

        It 'sets Zone 2 source with zone=2 XML' {
            Mock Get-DenonConfigXml {
                [xml]'<SourceList><Zone zone="2" index="10"><Source index="10"><Name>Phono</Name></Source></Zone></SourceList>'
            }
            Mock Invoke-DenonSetConfig { $script:LastSetType = $Type; $script:LastSetData = $Data }

            Set-DenonZone2Source -Name phono
            $script:LastSetType | Should -Be 7
            $script:LastSetData | Should -Be '<Source zone="2" index="10"></Source>'
        }
    }
}
