$script:ModuleRoot = Split-Path -Parent $PSCommandPath
$script:ManifestPath = Join-Path $script:ModuleRoot 'DenonAvrController.psd1'
Import-Module $script:ManifestPath -Force

BeforeAll {
    $script:ModuleRoot = $PSScriptRoot
    $script:ManifestPath = Join-Path $script:ModuleRoot 'DenonAvrController.psd1'
    Import-Module $script:ManifestPath -Force

    if (-not ('DenonAvrController.Tests.TlsTestServer' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;

namespace DenonAvrController.Tests
{
    public sealed class TlsTestServer : IDisposable
    {
        private readonly X509Certificate2 certificate;
        private readonly string body;
        private TcpListener listener;
        private Thread thread;

        public TlsTestServer(X509Certificate2 certificate, string body)
        {
            this.certificate = certificate;
            this.body = body;
        }

        public Uri Uri { get; private set; }
        public Exception Error { get; private set; }

        public void Start()
        {
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            Uri = new Uri("https://127.0.0.1:" + port.ToString() + "/test");
            thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Start();
        }

        private void Run()
        {
            try
            {
                using (TcpClient client = listener.AcceptTcpClient())
                using (SslStream ssl = new SslStream(client.GetStream(), false))
                {
                    ssl.AuthenticateAsServer(certificate, false, SslProtocols.Tls12, false);
                    using (StreamReader reader = new StreamReader(ssl, Encoding.ASCII, false, 1024, true))
                    {
                        string line;
                        while ((line = reader.ReadLine()) != null)
                        {
                            if (line.Length == 0)
                            {
                                break;
                            }
                        }
                    }

                    byte[] bodyBytes = Encoding.UTF8.GetBytes(body);
                    string header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: " + bodyBytes.Length.ToString() + "\r\nConnection: close\r\n\r\n";
                    byte[] headerBytes = Encoding.ASCII.GetBytes(header);
                    ssl.Write(headerBytes, 0, headerBytes.Length);
                    ssl.Write(bodyBytes, 0, bodyBytes.Length);
                    ssl.Flush();
                }
            }
            catch (Exception ex)
            {
                Error = ex;
            }
        }

        public void Dispose()
        {
            if (listener != null)
            {
                listener.Stop();
            }
            if (thread != null && thread.IsAlive)
            {
                thread.Join(2000);
            }
        }
    }
}
'@
    }
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

Describe 'Denon PowerShell TLS validation' {
    InModuleScope DenonAvrController {
        It 'uses a compiled callback for pinned public key HTTPS requests' {
            $rsa = [System.Security.Cryptography.RSA]::Create(2048)
            $certificate = $null
            try {
                $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
                    'CN=localhost',
                    $rsa,
                    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
                )
                $request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $false))
                $certificate = $request.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddDays(1))
                $pin = Get-DenonPinnedPublicKeyHash -Certificate $certificate

                $server = [DenonAvrController.Tests.TlsTestServer]::new($certificate, 'denon-ok')
                try {
                    try {
                        $server.Start()
                    }
                    catch [System.Management.Automation.MethodInvocationException] {
                        if ($_.Exception.Message -match 'Permission denied') {
                            Set-ItResult -Skipped -Because 'sandbox denied loopback listener creation'
                            return
                        }
                        throw
                    }
                    Invoke-DenonHttpClientGet -Uri $server.Uri.AbsoluteUri -TimeoutSeconds 5 -SkipCertificateCheck $true -PinnedPublicKey "sha256//$pin" | Should -Be 'denon-ok'
                }
                finally {
                    if ($null -ne $server) { $server.Dispose() }
                }

                $server = [DenonAvrController.Tests.TlsTestServer]::new($certificate, 'denon-ok')
                try {
                    $server.Start()
                    { Invoke-DenonHttpClientGet -Uri $server.Uri.AbsoluteUri -TimeoutSeconds 5 -SkipCertificateCheck $true -PinnedPublicKey 'sha256//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' } | Should -Throw
                }
                finally {
                    if ($null -ne $server) { $server.Dispose() }
                }

                $certPath = Join-Path ([System.IO.Path]::GetTempPath()) ('denon-test-{0}.cer' -f [System.Guid]::NewGuid().ToString('N'))
                try {
                    [System.IO.File]::WriteAllBytes($certPath, $certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
                    $server = [DenonAvrController.Tests.TlsTestServer]::new($certificate, 'denon-ca-ok')
                    try {
                        $server.Start()
                        Invoke-DenonHttpClientGet -Uri $server.Uri.AbsoluteUri -TimeoutSeconds 5 -SkipCertificateCheck $false -CaCert $certPath | Should -Be 'denon-ca-ok'
                    }
                    finally {
                        if ($null -ne $server) { $server.Dispose() }
                    }
                }
                finally {
                    Remove-Item -LiteralPath $certPath -Force -ErrorAction SilentlyContinue
                }
            }
            finally {
                if ($null -ne $certificate) { $certificate.Dispose() }
                $rsa.Dispose()
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

Describe 'Denon PowerShell parity additions' {
    InModuleScope DenonAvrController {
        BeforeEach {
            $script:DenonReceiverConfig.IpAddress = '192.0.2.10'
            $script:DenonReceiverConfig.SkipCertificateCheck = $true
            $script:DenonReceiverConfig.MaxVolumeDb = -10.0
        }

        It 'exports the signal-debug and volume fade public commands' {
            $commands = @(Get-Command -Module DenonAvrController | Select-Object -ExpandProperty Name)
            $commands | Should -Contain 'Get-DenonSignalDebug'
            $commands | Should -Contain 'Invoke-DenonVolumeFade'
        }

        It 'supports volume fade WhatIf and still enforces the max-volume cap' {
            Mock Resolve-DenonReceiver { [pscustomobject]@{ IpAddress = '192.0.2.10'; Port = 10443; BaseUri = 'https://192.0.2.10:10443'; TimeoutSeconds = 1; SkipCertificateCheck = $true } }
            Mock Get-DenonConfigXml { [xml]'<item><MainZone><Volume>400</Volume></MainZone></item>' }
            Mock Get-DenonXmlValue { '400' }
            Mock Invoke-DenonSetConfig { throw 'WhatIf should not send volume updates' }

            $result = Invoke-DenonVolumeFade -45 -DurationSeconds 1 -WhatIf
            $result.Action | Should -Be 'VolumeFade'
            $result.Changed | Should -BeFalse
            Should -Invoke Invoke-DenonSetConfig -Times 0
            { Invoke-DenonVolumeFade -5 -DurationSeconds 1 } | Should -Throw -ExpectedMessage '*MaxVolumeDb=-10.0*'
        }

        It 'returns signal-debug raw field shape without decoder guessing' {
            Mock Get-DenonStatus { [pscustomobject]@{ SourceIndex = 13; SourceName = 'HEOS Music' } }
            Mock Get-DenonSources { @([pscustomobject]@{ Zone = 1; Index = 13; DisplayName = 'HEOS Music'; ReceiverName = 'HEOS Music'; Active = $true }) }
            Mock Invoke-DenonTelnetCommand {
                [pscustomobject]@{ ReceivedResponse = $true; Response = "$Command`r`nOPINF_SAMPLE`r`nMSDOLBY`r`n" }
            }

            $debug = Get-DenonSignalDebug
            $debug.Title | Should -Be 'Signal diagnostics'
            $debug.DecoderStatus | Should -Match 'no proven'
            $debug.SelectedSource.Index | Should -Be 13
            $debug.RawTelnetFields.SI.Count | Should -BeGreaterThan 0
            $debug.SignalPresence | Should -Match 'undecoded'
        }

        It 'binds the dashboard parity parameters' {
            $parameters = (Get-Command Show-DenonDashboard).Parameters
            foreach ($name in @('Watch', 'IntervalSeconds', 'Diagnostics', 'Ascii', 'Unicode', 'Color')) {
                $parameters.Keys | Should -Contain $name
            }
        }

        It 'normalizes IPv4 candidates and rejects non-IPv4 values' {
            ConvertTo-_DenonNormalizeIPv4 -Value ' 192.0.2.55 ' | Should -Be '192.0.2.55'
            ConvertTo-_DenonNormalizeIPv4 -Value 'not-an-ip' | Should -BeNullOrEmpty
            ConvertTo-_DenonNormalizeIPv4 -Value '2001:db8::1' | Should -BeNullOrEmpty
        }

        It 'uses mocked native mDNS discovery after configured candidates' {
            Mock Get-DenonConfiguredValue {
                if ($Name -eq 'DENON_SSDP_TIMEOUT') { '0.01' } else { $null }
            }
            Mock Get-DenonPlatformPath { Join-Path ([System.IO.Path]::GetTempPath()) 'missing-denon-cache-for-test' }
            Mock Get-_DenonMdnsCandidate { @('192.0.2.44') }
            Mock Invoke-DenonReceiverCandidateProbe {
                if ($Candidate -contains '192.0.2.44') {
                    [pscustomobject]@{ IpAddress = '192.0.2.44'; Responded = $true; IsDenon = $true }
                }
            }
            Mock Get-_DenonArpCandidate { @('192.0.2.45') }

            $found = Find-DenonReceiver
            $found.IpAddress | Should -Be '192.0.2.44'
            Should -Invoke Get-_DenonMdnsCandidate -Times 1
            Should -Invoke Get-_DenonArpCandidate -Times 0
        }

        It 'falls back to mocked ARP discovery when earlier tiers do not match' {
            Mock Get-DenonConfiguredValue {
                if ($Name -eq 'DENON_SSDP_TIMEOUT') { '0.01' } else { $null }
            }
            Mock Get-DenonPlatformPath { Join-Path ([System.IO.Path]::GetTempPath()) 'missing-denon-cache-for-test' }
            Mock Get-_DenonMdnsCandidate { @() }
            Mock Get-_DenonArpCandidate { @('192.0.2.45') }
            Mock Invoke-DenonReceiverCandidateProbe {
                if ($Candidate -contains '192.0.2.45') {
                    [pscustomobject]@{ IpAddress = '192.0.2.45'; Responded = $true; IsDenon = $true }
                }
            }

            $found = Find-DenonReceiver
            $found.IpAddress | Should -Be '192.0.2.45'
            Should -Invoke Get-_DenonMdnsCandidate -Times 1
            Should -Invoke Get-_DenonArpCandidate -Times 1
        }
    }
}
