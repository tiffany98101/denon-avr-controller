BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSCommandPath
    $script:ManifestPath = Join-Path $script:ModuleRoot 'DenonAvrController.psd1'
    Import-Module $script:ManifestPath -Force
}

Describe 'DenonAvrController manifest and exports' {
    It 'has a valid manifest' {
        $manifest = Test-ModuleManifest $script:ManifestPath
        $manifest.Name | Should -Be 'DenonAvrController'
        $manifest.Version.ToString() | Should -Be '1.2.0'
        $manifest.RootModule | Should -Be 'DenonAvrController.psm1'
    }

    It 'exports public commands and hides private helpers' {
        $commands = @(Get-Command -Module DenonAvrController)
        $commands.Name | Should -Contain 'Get-DenonStatus'
        $commands.Name | Should -Contain 'Get-DenonReceiverSummary'
        $commands.Name | Should -Contain 'Get-DenonNowPlaying'
        $commands.Name | Should -Not -Contain 'ConvertTo-DenonMuteBoolean'
        $commands.Name | Should -Not -Contain 'Get-DenonStatusFromXml'
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
