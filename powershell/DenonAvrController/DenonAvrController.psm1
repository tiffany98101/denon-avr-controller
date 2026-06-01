$script:DenonControllerVersion = '1.2.0-beta.4'
$script:DenonKnownConfigKeys = @(
    'DENON_IP',
    'DENON_DEFAULT_IP',
    'DENON_SCAN_LAN',
    'DENON_MAX_VOLUME_DB',
    'DENON_VOLUME_STEP_DB',
    'DENON_SOURCE_ALIASES',
    'DENON_CURL_CONNECT_TIMEOUT',
    'DENON_CURL_MAX_TIME',
    'DENON_CURL_INSECURE',
    'DENON_CURL_CACERT',
    'DENON_CURL_PINNEDPUBKEY',
    'DENON_SSDP_TIMEOUT',
    'DENON_SSDP_MX',
    'DENON_HEOS_PID',
    'DENON_HEOS_GID',
    'DENON_HEOS_HELPER',
    'DENON_HEOS_TIMEOUT',
    'DENON_DATA_DISCOVERY_MAX_TYPE',
    'DENON_CACHE_TTL_SECONDS',
    'DENON_LOCK',
    'DENON_LOCK_TIMEOUT',
    'DENON_DEBUG',
    'NO_COLOR'
)

$script:DenonCommandSurface = @(
    'info', 'data', 'status', 'signal-debug', 'rawstatus', 'raw', 'snapshot', 'diff',
    'dashboard', 'dashboard-alt', 'sources', 'source', 'rename-source',
    'source-names', 'clear-source-name', 'sleep', 'qs', 'quick', 'quick-select',
    'on', 'off', 'xbox', 'xfinity', 'bluray', 'tv', 'phono', 'heos', 'vol',
    'up', 'down', 'mute', 'unmute', 'toggle', 'movie', 'game', 'night', 'music',
    'mode', 'dyn-eq', 'dyn-vol', 'cinema-eq', 'multeq', 'bass', 'treble',
    'play', 'pause', 'stop', 'next', 'prev', 'previous', 'track', 'now',
    'zone2', 'watch-event', 'preset', 'discover', 'doctor', 'setip',
    'config', 'profile', 'completion', 'version', 'help'
)

$script:DenonHeosCommandSurface = @(
    'now', 'play', 'pause', 'stop', 'next', 'prev', 'previous', 'queue',
    'groups', 'group', 'browse', 'search', 'play-stream', 'repeat', 'shuffle',
    'update', 'get-volume'
)

$script:DenonReceiverConfig = [ordered]@{
    IpAddress = $null
    Port = 10443
    Name = $null
    TimeoutSeconds = 4
    TelnetPort = 23
    SkipCertificateCheck = $null
    MaxVolumeDb = -10.0
}

function Get-DenonPlatformPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Config', 'Cache', 'Data')]
        [string]$Kind
    )

    switch ($Kind) {
        'Config' {
            $override = [Environment]::GetEnvironmentVariable('DENON_CONFIG')
            if (-not [string]::IsNullOrWhiteSpace($override)) { return $override }
            $xdg = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME')
            if (-not [string]::IsNullOrWhiteSpace($xdg)) { return (Join-Path $xdg 'denon/config') }
            $appData = [Environment]::GetFolderPath('ApplicationData')
            if (-not [string]::IsNullOrWhiteSpace($appData)) { return (Join-Path $appData 'denon/config') }
            return (Join-Path $HOME '.config/denon/config')
        }
        'Cache' {
            $xdg = [Environment]::GetEnvironmentVariable('XDG_CACHE_HOME')
            $base = if (-not [string]::IsNullOrWhiteSpace($xdg)) {
                $xdg
            }
            else {
                $local = [Environment]::GetFolderPath('LocalApplicationData')
                if (-not [string]::IsNullOrWhiteSpace($local)) { $local } else { Join-Path $HOME '.cache' }
            }
            $profile = [Environment]::GetEnvironmentVariable('DENON_PROFILE')
            $name = if ([string]::IsNullOrWhiteSpace($profile)) { 'denon_ip' } else { 'denon_ip.{0}' -f $profile }
            return (Join-Path $base $name)
        }
        'Data' {
            $xdg = [Environment]::GetEnvironmentVariable('XDG_DATA_HOME')
            if (-not [string]::IsNullOrWhiteSpace($xdg)) { return (Join-Path $xdg 'denon') }
            $appData = [Environment]::GetFolderPath('ApplicationData')
            if (-not [string]::IsNullOrWhiteSpace($appData)) { return (Join-Path $appData 'denon') }
            return (Join-Path $HOME '.local/share/denon')
        }
    }
}

function Test-DenonStoredName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Name.Contains('/') -or $Name.Contains('\')) {
        throw ('{0} name must not contain a path separator: {1}' -f $Kind, $Name)
    }
    if ($Name.StartsWith('.', [System.StringComparison]::Ordinal)) {
        throw ('{0} name must not start with ".": {1}' -f $Kind, $Name)
    }
}

function Read-DenonKeyValueFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $values = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $values
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $clean = ($line -replace '#.*$', '').Trim()
        if ([string]::IsNullOrWhiteSpace($clean) -or $clean -notmatch '=') { continue }
        $key, $value = $clean -split '=', 2
        $values[$key.Trim()] = $value
    }

    $values
}

function Set-DenonKeyValueFileValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $Path) {
            if ($line -notmatch ('^{0}=' -f [regex]::Escape($Key))) {
                $lines.Add($line)
            }
        }
    }
    $lines.Add(('{0}={1}' -f $Key, $Value))
    Set-Content -LiteralPath $Path -Value $lines -Encoding utf8
}

function Remove-DenonKeyValueFileValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $lines = @(Get-Content -LiteralPath $Path | Where-Object { $_ -notmatch ('^{0}=' -f [regex]::Escape($Key)) })
    Set-Content -LiteralPath $Path -Value $lines -Encoding utf8
    $true
}

function Import-DenonConfigurationFile {
    [CmdletBinding()]
    param(
        [string]$Path = (Get-DenonPlatformPath -Kind Config)
    )

    $values = Read-DenonKeyValueFile -Path $Path
    foreach ($key in $script:DenonKnownConfigKeys) {
        if ($values.Contains($key) -and [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($key))) {
            [Environment]::SetEnvironmentVariable($key, [string]$values[$key], 'Process')
        }
    }
}

function Get-DenonConfiguredValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        return $value
    }

    $config = Read-DenonKeyValueFile -Path (Get-DenonPlatformPath -Kind Config)
    if ($config.Contains($Name)) {
        return [string]$config[$Name]
    }

    return $null
}

function Get-DenonTlsSettings {
    [CmdletBinding()]
    param()

    $insecure = Get-DenonConfiguredValue -Name 'DENON_CURL_INSECURE'
    $cacert = Get-DenonConfiguredValue -Name 'DENON_CURL_CACERT'
    $pinned = Get-DenonConfiguredValue -Name 'DENON_CURL_PINNEDPUBKEY'

    [pscustomobject]@{
        SkipCertificateCheck = if ($insecure -eq '0' -or -not [string]::IsNullOrWhiteSpace($cacert)) { $false } else { $true }
        CaCert = $cacert
        PinnedPublicKey = $pinned
    }
}

function Resolve-DenonReceiver {
    [CmdletBinding()]
    param()

    Import-DenonConfigurationFile
    $ipAddress = $script:DenonReceiverConfig.IpAddress
    if ([string]::IsNullOrWhiteSpace($ipAddress)) {
        $ipAddress = Get-DenonConfiguredValue -Name 'DENON_IP'
    }
    if ([string]::IsNullOrWhiteSpace($ipAddress)) {
        $cachePath = Get-DenonPlatformPath -Kind Cache
        if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
            $cached = (Get-Content -LiteralPath $cachePath -Raw).Trim()
            if ($cached -match '^[0-9]{1,3}(\.[0-9]{1,3}){3}$') {
                $ipAddress = $cached
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($ipAddress)) {
        $ipAddress = Get-DenonConfiguredValue -Name 'DENON_DEFAULT_IP'
    }
    if ([string]::IsNullOrWhiteSpace($ipAddress)) {
        throw 'No Denon receiver IP is configured. Run Set-DenonReceiver -IpAddress <address>, Set-DenonReceiverIp <address>, or set DENON_IP/DENON_DEFAULT_IP.'
    }

    $timeout = $script:DenonReceiverConfig.TimeoutSeconds
    $maxTime = Get-DenonConfiguredValue -Name 'DENON_CURL_MAX_TIME'
    if (-not [string]::IsNullOrWhiteSpace($maxTime)) {
        $parsedTimeout = 0
        if ([int]::TryParse($maxTime, [ref]$parsedTimeout) -and $parsedTimeout -gt 0) {
            $timeout = $parsedTimeout
        }
    }
    $tls = Get-DenonTlsSettings

    [pscustomobject]@{
        IpAddress = $ipAddress
        Port = [int]$script:DenonReceiverConfig.Port
        Name = $script:DenonReceiverConfig.Name
        TimeoutSeconds = [int]$timeout
        TelnetPort = [int]$script:DenonReceiverConfig.TelnetPort
        SkipCertificateCheck = if ($null -ne $script:DenonReceiverConfig.SkipCertificateCheck) { [bool]$script:DenonReceiverConfig.SkipCertificateCheck } else { [bool]$tls.SkipCertificateCheck }
        CaCert = $tls.CaCert
        PinnedPublicKey = $tls.PinnedPublicKey
        MaxVolumeDb = [double]$script:DenonReceiverConfig.MaxVolumeDb
        BaseUri = ('https://{0}:{1}' -f $ipAddress, [int]$script:DenonReceiverConfig.Port)
    }
}

function Set-DenonReceiver {
    <#
    .SYNOPSIS
    Configures the Denon receiver for this PowerShell session.

    .DESCRIPTION
    Stores the receiver address in module memory. If no address is configured,
    read commands fall back to DENON_IP, then DENON_DEFAULT_IP. Volume-changing
    commands refuse targets above MaxVolumeDb, which defaults to -10.0 dB,
    unless the command is run with -AllowAboveMaxVolume.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$IpAddress,

        [ValidateRange(1, 65535)]
        [int]$Port = 10443,

        [ValidateRange(1, 65535)]
        [int]$TelnetPort,

        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds,

        [ValidateRange(-80.0, 18.0)]
        [double]$MaxVolumeDb,

        [string]$Name,

        [switch]$SkipCertificateCheck
    )

    if ([string]::IsNullOrWhiteSpace($IpAddress)) {
        $IpAddress = [Environment]::GetEnvironmentVariable('DENON_IP')
    }
    if ([string]::IsNullOrWhiteSpace($IpAddress)) {
        $IpAddress = [Environment]::GetEnvironmentVariable('DENON_DEFAULT_IP')
    }
    if ([string]::IsNullOrWhiteSpace($IpAddress)) {
        throw 'IpAddress is required unless DENON_IP or DENON_DEFAULT_IP is set.'
    }

    $script:DenonReceiverConfig.IpAddress = $IpAddress
    if ($PSBoundParameters.ContainsKey('Port')) {
        $script:DenonReceiverConfig.Port = $Port
    }
    if ($PSBoundParameters.ContainsKey('TelnetPort')) {
        $script:DenonReceiverConfig.TelnetPort = $TelnetPort
    }
    if ($PSBoundParameters.ContainsKey('TimeoutSeconds')) {
        $script:DenonReceiverConfig.TimeoutSeconds = $TimeoutSeconds
    }
    if ($PSBoundParameters.ContainsKey('SkipCertificateCheck')) {
        $script:DenonReceiverConfig.SkipCertificateCheck = $SkipCertificateCheck.IsPresent
    }
    if ($PSBoundParameters.ContainsKey('MaxVolumeDb')) {
        $script:DenonReceiverConfig.MaxVolumeDb = $MaxVolumeDb
    }
    if ($PSBoundParameters.ContainsKey('Name')) {
        $script:DenonReceiverConfig.Name = $Name
    }

    Resolve-DenonReceiver
}

function ConvertTo-DenonQueryValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    [System.Uri]::EscapeDataString($Value)
}

function Test-DenonHeosPlayerId {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$PlayerId
    )

    -not [string]::IsNullOrWhiteSpace($PlayerId) -and $PlayerId -match '^-?[0-9]+$'
}

function Get-DenonPinnedPublicKeyHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $publicKey = $null
    try {
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($Certificate)
        if ($null -ne $rsa) {
            try { $publicKey = $rsa.ExportSubjectPublicKeyInfo() }
            finally { $rsa.Dispose() }
        }

        if ($null -eq $publicKey) {
            $ecdsa = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPublicKey($Certificate)
            if ($null -ne $ecdsa) {
                try { $publicKey = $ecdsa.ExportSubjectPublicKeyInfo() }
                finally { $ecdsa.Dispose() }
            }
        }

        if ($null -eq $publicKey) {
            $dsa = [System.Security.Cryptography.X509Certificates.DSACertificateExtensions]::GetDSAPublicKey($Certificate)
            if ($null -ne $dsa) {
                try { $publicKey = $dsa.ExportSubjectPublicKeyInfo() }
                finally { $dsa.Dispose() }
            }
        }

        if ($null -eq $publicKey) {
            $publicKey = $Certificate.GetPublicKey()
        }

        [Convert]::ToBase64String($sha256.ComputeHash($publicKey))
    }
    finally {
        $sha256.Dispose()
    }
}

function Test-DenonCertificateWithCustomTrust {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,

        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$TrustedCertificate
    )

    if ($Certificate.GetCertHashString() -eq $TrustedCertificate.GetCertHashString()) {
        return $true
    }

    $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
        if ($chain.ChainPolicy.PSObject.Properties.Name -contains 'TrustMode') {
            $chain.ChainPolicy.TrustMode = [System.Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
            [void]$chain.ChainPolicy.CustomTrustStore.Add($TrustedCertificate)
        }
        else {
            [void]$chain.ChainPolicy.ExtraStore.Add($TrustedCertificate)
        }
        $chain.Build($Certificate)
    }
    finally {
        $chain.Dispose()
    }
}

function Invoke-DenonHttpClientGet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [int]$TimeoutSeconds = 4,

        [bool]$SkipCertificateCheck = $false,

        [string]$CaCert,

        [string]$PinnedPublicKey
    )

    if (-not [string]::IsNullOrWhiteSpace($PinnedPublicKey) -and $PinnedPublicKey -notmatch '^sha256//(.+)$') {
        throw 'PowerShell DENON_CURL_PINNEDPUBKEY supports sha256//BASE64HASH pins.'
    }

    $trustedCertificate = $null
    if (-not [string]::IsNullOrWhiteSpace($CaCert)) {
        if (-not (Test-Path -LiteralPath $CaCert -PathType Leaf)) {
            throw ('DENON_CURL_CACERT file was not found: {0}' -f $CaCert)
        }
        $trustedCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CaCert)
    }

    $expectedPin = $null
    if (-not [string]::IsNullOrWhiteSpace($PinnedPublicKey)) {
        $expectedPin = $PinnedPublicKey -replace '^sha256//', ''
    }

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $client = $null
    try {
        $handler.ServerCertificateCustomValidationCallback = {
            param($requestMessage, $certificate, $chain, $sslPolicyErrors)

            try {
                $certificate2 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certificate)
                if (-not [string]::IsNullOrWhiteSpace($expectedPin)) {
                    $actualPin = Get-DenonPinnedPublicKeyHash -Certificate $certificate2
                    if ($actualPin -ne $expectedPin) {
                        return $false
                    }
                }

                if ($null -ne $trustedCertificate) {
                    return (Test-DenonCertificateWithCustomTrust -Certificate $certificate2 -TrustedCertificate $trustedCertificate)
                }

                if ($SkipCertificateCheck) {
                    return $true
                }

                return ($sslPolicyErrors -eq [System.Net.Security.SslPolicyErrors]::None)
            }
            catch {
                return $false
            }
        }

        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Uri)
        $request.Headers.UserAgent.ParseAdd(('DenonAvrController.PowerShell/{0}' -f $script:DenonControllerVersion))
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode() | Out-Null
        $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
    finally {
        if ($null -ne $client) { $client.Dispose() }
        $handler.Dispose()
        if ($null -ne $trustedCertificate) { $trustedCertificate.Dispose() }
    }
}

function Invoke-DenonHttpGet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [int]$TimeoutSeconds = 4,

        [bool]$SkipCertificateCheck = $false,

        [string]$CaCert,

        [string]$PinnedPublicKey
    )

    Write-Verbose "GET $Uri"

    $command = Get-Command Invoke-WebRequest -ErrorAction Stop
    $parameters = @{
        Uri = $Uri
        Method = 'Get'
        TimeoutSec = $TimeoutSeconds
        ErrorAction = 'Stop'
        Headers = @{ 'User-Agent' = ('DenonAvrController.PowerShell/{0}' -f $script:DenonControllerVersion) }
    }

    if ($command.Parameters.ContainsKey('UseBasicParsing')) {
        $parameters['UseBasicParsing'] = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($CaCert) -and -not (Test-Path -LiteralPath $CaCert -PathType Leaf)) {
        throw ('DENON_CURL_CACERT file was not found: {0}' -f $CaCert)
    }
    if (-not [string]::IsNullOrWhiteSpace($CaCert) -or -not [string]::IsNullOrWhiteSpace($PinnedPublicKey)) {
        try {
            return Invoke-DenonHttpClientGet -Uri $Uri -TimeoutSeconds $TimeoutSeconds -SkipCertificateCheck $SkipCertificateCheck -CaCert $CaCert -PinnedPublicKey $PinnedPublicKey
        }
        catch {
            $hint = ''
            if (-not $SkipCertificateCheck -and $_.Exception.Message -match 'certificate|SSL|TLS|trust') {
                $hint = ' If this receiver uses a self-signed certificate, set DENON_CURL_INSECURE=1 or run Set-DenonReceiver again with -SkipCertificateCheck.'
            }
            throw ('Denon HTTP request failed for {0}: {1}{2}' -f $Uri, $_.Exception.Message, $hint)
        }
    }

    if ($SkipCertificateCheck -and $command.Parameters.ContainsKey('SkipCertificateCheck')) {
        $parameters['SkipCertificateCheck'] = $true
    }

    try {
        $response = Invoke-WebRequest @parameters
        return [string]$response.Content
    }
    catch {
        $hint = ''
        if (-not $SkipCertificateCheck -and $_.Exception.Message -match 'certificate|SSL|TLS|trust') {
            $hint = ' If this receiver uses a self-signed certificate, set DENON_CURL_INSECURE=1 or run Set-DenonReceiver again with -SkipCertificateCheck.'
        }
        throw ('Denon HTTP request failed for {0}: {1}{2}' -f $Uri, $_.Exception.Message, $hint)
    }
}

function Invoke-DenonGetConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)]
        [int]$Type,

        [psobject]$Receiver = (Resolve-DenonReceiver)
    )

    $uri = '{0}/ajax/globals/get_config?type={1}' -f $Receiver.BaseUri, $Type
    Invoke-DenonHttpGet -Uri $uri -TimeoutSeconds $Receiver.TimeoutSeconds -SkipCertificateCheck $Receiver.SkipCertificateCheck -CaCert $Receiver.CaCert -PinnedPublicKey $Receiver.PinnedPublicKey
}

function Invoke-DenonSetConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(4, 7, 12)]
        [int]$Type,

        [Parameter(Mandatory = $true)]
        [string]$Data,

        [psobject]$Receiver = (Resolve-DenonReceiver)
    )

    Write-Verbose ('set_config type={0} data={1}' -f $Type, $Data)
    $encodedData = ConvertTo-DenonQueryValue -Value $Data
    $uri = '{0}/ajax/globals/set_config?type={1}&data={2}' -f $Receiver.BaseUri, $Type, $encodedData
    [void](Invoke-DenonHttpGet -Uri $uri -TimeoutSeconds $Receiver.TimeoutSeconds -SkipCertificateCheck $Receiver.SkipCertificateCheck -CaCert $Receiver.CaCert -PinnedPublicKey $Receiver.PinnedPublicKey)
}

function ConvertTo-DenonXmlDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$XmlText
    )

    if ([string]::IsNullOrWhiteSpace($XmlText)) {
        throw 'Receiver returned empty XML.'
    }

    try {
        return [xml]$XmlText
    }
    catch {
        throw ('Receiver returned XML that could not be parsed: {0}' -f $_.Exception.Message)
    }
}

function Get-DenonConfigXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)]
        [int]$Type,

        [psobject]$Receiver = (Resolve-DenonReceiver)
    )

    ConvertTo-DenonXmlDocument -XmlText (Invoke-DenonGetConfig -Type $Type -Receiver $Receiver)
}

function Get-DenonOptionalConfigXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)]
        [int]$Type,

        [psobject]$Receiver = (Resolve-DenonReceiver)
    )

    try {
        Get-DenonConfigXml -Type $Type -Receiver $Receiver
    }
    catch {
        Write-Verbose ('get_config type={0} unavailable: {1}' -f $Type, $_.Exception.Message)
        return $null
    }
}

function Invoke-DenonPlainHttpGet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [ValidateRange(1, 65535)]
        [int]$Port = 80,

        [psobject]$Receiver = (Resolve-DenonReceiver)
    )

    $uri = if ($Port -eq 80) {
        'http://{0}{1}' -f $Receiver.IpAddress, $Path
    }
    else {
        'http://{0}:{1}{2}' -f $Receiver.IpAddress, $Port, $Path
    }

    Invoke-DenonHttpGet -Uri $uri -TimeoutSeconds $Receiver.TimeoutSeconds -SkipCertificateCheck:$false
}

function Get-DenonXmlValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [xml]$Xml,

        [Parameter(Mandatory = $true)]
        [string]$XPath
    )

    $node = $Xml.SelectSingleNode($XPath)
    if ($null -eq $node) {
        return $null
    }
    if ($node -is [System.Xml.XmlAttribute]) {
        return ([string]$node.Value).Trim()
    }

    ([string]$node.InnerText).Trim()
}

function Get-DenonChildText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlNode]$Node,

        [Parameter(Mandatory = $true)]
        [string]$ChildName
    )

    $child = $Node.SelectSingleNode(('*[local-name()="{0}"]' -f $ChildName))
    if ($null -eq $child) {
        return $null
    }

    ([string]$child.InnerText).Trim()
}

function ConvertTo-DenonNullableInt {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $parsed = 0
    if ([int]::TryParse($Value, [ref]$parsed)) {
        return $parsed
    }

    return $null
}

function ConvertTo-DenonPowerName {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Code
    )

    if ([string]::IsNullOrWhiteSpace($Code)) {
        return 'Unknown'
    }

    switch ($Code) {
        '1' { 'ON'; break }
        '2' { 'STANDBY'; break }
        '3' { 'OFF'; break }
        default { 'UNKNOWN({0})' -f $Code; break }
    }
}

function ConvertTo-DenonMuteBoolean {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Code
    )

    $value = if ($null -eq $Code) { '' } else { ([string]$Code).Trim() }
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    switch -Regex ($value.ToLowerInvariant()) {
        '^(1|on|yes|true|muon|z2muon)$' { return $true }
        '^(0|2|off|no|false|muoff|z2muoff)$' { return $false }
        default { return $null }
    }
}

function ConvertTo-DenonMuteLabel {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Muted
    )

    if ($Muted -eq $true) {
        return 'yes'
    }
    if ($Muted -eq $false) {
        return 'no'
    }

    'Unknown'
}

function Get-DenonTelnetResponseLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string]$Prefix
    )

    try {
        $result = Invoke-DenonTelnetCommand -Command $Command -ReadResponse -TimeoutMilliseconds 1500
    }
    catch {
        return $null
    }

    if (-not $result.ReceivedResponse) {
        return $null
    }

    $lines = @($result.Response -split "`r`n|`n|`r" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($line in $lines) {
        if ($line.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $line
        }
    }

    return $null
}

function Get-DenonMuteCode {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$XmlCode,

        [ValidateSet('Main', 'Zone2')]
        [string]$Zone = 'Main',

        [switch]$PreferTelnet
    )

    if ($PreferTelnet.IsPresent) {
        $command = if ($Zone -eq 'Zone2') { 'Z2MU?' } else { 'MU?' }
        $prefix = if ($Zone -eq 'Zone2') { 'Z2MU' } else { 'MU' }
        $telnetCode = Get-DenonTelnetResponseLine -Command $command -Prefix $prefix
        if ($null -ne (ConvertTo-DenonMuteBoolean -Code $telnetCode)) {
            return $telnetCode
        }
    }

    $XmlCode
}

function ConvertFrom-DenonRawVolume {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Raw
    )

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return $null
    }

    [Math]::Round(([double]$Raw / 10.0) - 80.0, 1)
}

function ConvertTo-DenonRawVolume {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [double]$Db
    )

    $raw = [int][Math]::Round(($Db + 80.0) * 10.0, 0, [MidpointRounding]::AwayFromZero)
    if ($raw -lt 0 -or $raw -gt 980) {
        throw ('Volume {0} dB is outside the Denon raw range 0..980 (-80.0 dB to 18.0 dB).' -f $Db)
    }

    $raw
}

function Assert-DenonVolumeWithinMax {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [double]$Db,

        [switch]$AllowAboveMaxVolume
    )

    if ($AllowAboveMaxVolume.IsPresent) {
        return
    }

    $maxVolumeDb = [double]$script:DenonReceiverConfig.MaxVolumeDb
    if ($Db -gt $maxVolumeDb) {
        throw ('Refusing to set volume above MaxVolumeDb={0:N1} dB. Pass -AllowAboveMaxVolume to override for this command.' -f $maxVolumeDb)
    }
}

function ConvertTo-DenonSourceKey {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    ([regex]::Replace($Value.ToLowerInvariant(), '[^a-z0-9]', ''))
}

function Get-DenonSourceAliasPath {
    [CmdletBinding()]
    param()

    $configured = Get-DenonConfiguredValue -Name 'DENON_SOURCE_ALIASES'
    if (-not [string]::IsNullOrWhiteSpace($configured) -and $configured -notmatch '=') {
        return $configured
    }

    $configRoot = Split-Path -Parent (Get-DenonPlatformPath -Kind Config)
    if ([string]::IsNullOrWhiteSpace($configRoot)) {
        $configRoot = Join-Path $HOME '.config/denon'
    }
    Join-Path $configRoot 'source_aliases'
}

function Read-DenonSourceAliases {
    [CmdletBinding()]
    param()

    $aliases = @{}
    $inline = Get-DenonConfiguredValue -Name 'DENON_SOURCE_ALIASES'
    if (-not [string]::IsNullOrWhiteSpace($inline) -and $inline -match '=') {
        foreach ($part in $inline -split ',') {
            if ($part -notmatch '=') { continue }
            $key, $value = $part -split '=', 2
            $key = $key.Trim()
            if ($key -match '^([0-9]+):([0-9]+)$') {
                $aliases['{0}:{1}' -f $Matches[1], $Matches[2]] = $value.Trim()
            }
            elseif ($key -match '^[0-9]+$') {
                $aliases['1:{0}' -f $key] = $value.Trim()
            }
        }
    }

    $path = Get-DenonSourceAliasPath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $path) {
            $parts = $line -split "`t", 3
            if ($parts.Count -eq 3) {
                $aliases['{0}:{1}' -f $parts[0], $parts[1]] = $parts[2]
            }
        }
    }

    $aliases
}

function Get-DenonSourceRowsFromXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [xml]$SourceXml,

        [Parameter(Mandatory = $true)]
        [ValidateSet(1, 2)]
        [int]$Zone
    )

    $zoneNode = $SourceXml.SelectSingleNode(('//*[local-name()="Zone" and @zone="{0}"]' -f $Zone))
    if ($null -eq $zoneNode) {
        return
    }

    $activeIndex = ConvertTo-DenonNullableInt -Value $zoneNode.GetAttribute('index')
    $sourceNodes = $zoneNode.SelectNodes('*[local-name()="Source"]')

    $aliases = Read-DenonSourceAliases
    foreach ($sourceNode in $sourceNodes) {
        $index = ConvertTo-DenonNullableInt -Value $sourceNode.GetAttribute('index')
        $receiverName = Get-DenonChildText -Node $sourceNode -ChildName 'Name'
        if ([string]::IsNullOrWhiteSpace($receiverName)) {
            $receiverName = 'Unknown'
        }
        $aliasKey = '{0}:{1}' -f $Zone, $index
        $displayName = if ($aliases.ContainsKey($aliasKey)) { [string]$aliases[$aliasKey] } else { $receiverName }

        [pscustomobject]@{
            Zone = $Zone
            Index = $index
            ReceiverName = $receiverName
            DisplayName = $displayName
            Active = ($null -ne $index -and $index -eq $activeIndex)
        }
    }
}

function Get-DenonSourceNameFromXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [xml]$SourceXml,

        [Parameter(Mandatory = $true)]
        [ValidateSet(1, 2)]
        [int]$Zone,

        [AllowNull()]
        [object]$Index
    )

    if ($null -eq $Index -or [string]::IsNullOrWhiteSpace([string]$Index)) {
        return $null
    }

    $sourceIndex = [int]$Index
    $sources = @(Get-DenonSourceRowsFromXml -SourceXml $SourceXml -Zone $Zone)
    foreach ($source in $sources) {
        if ($source.Index -eq $sourceIndex) {
            return $source.DisplayName
        }
    }

    return $null
}

function Get-DenonStatusFromXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Receiver,

        [Parameter(Mandatory = $true)]
        [xml]$PowerXml,

        [Parameter(Mandatory = $true)]
        [xml]$SourceXml,

        [Parameter(Mandatory = $true)]
        [xml]$VolumeXml
    )

    $powerCode = Get-DenonXmlValue -Xml $PowerXml -XPath '//*[local-name()="MainZone"]/*[local-name()="Power"]'
    $sourceIndex = ConvertTo-DenonNullableInt -Value (Get-DenonXmlValue -Xml $SourceXml -XPath '//*[local-name()="Zone" and @zone="1"]/@index')
    $rawVolume = Get-DenonXmlValue -Xml $VolumeXml -XPath '//*[local-name()="MainZone"]/*[local-name()="Volume"]'
    $xmlMuteCode = Get-DenonXmlValue -Xml $VolumeXml -XPath '//*[local-name()="MainZone"]/*[local-name()="Mute"]'
    $muteCode = Get-DenonMuteCode -XmlCode $xmlMuteCode -Zone Main -PreferTelnet
    $sourceName = Get-DenonSourceNameFromXml -SourceXml $SourceXml -Zone 1 -Index $sourceIndex

    [pscustomobject]@{
        IpAddress = $Receiver.IpAddress
        Power = ConvertTo-DenonPowerName -Code $powerCode
        SourceIndex = $sourceIndex
        SourceName = if ([string]::IsNullOrWhiteSpace($sourceName)) { 'Unknown' } else { $sourceName }
        VolumeRaw = ConvertTo-DenonNullableInt -Value $rawVolume
        VolumeDb = ConvertFrom-DenonRawVolume -Raw $rawVolume
        Muted = ConvertTo-DenonMuteBoolean -Code $muteCode
        MuteRaw = $muteCode
        MuteXmlRaw = $xmlMuteCode
    }
}

function Get-DenonZone2StatusFromXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Receiver,

        [Parameter(Mandatory = $true)]
        [xml]$PowerXml,

        [Parameter(Mandatory = $true)]
        [xml]$SourceXml,

        [Parameter(Mandatory = $true)]
        [xml]$VolumeXml
    )

    $powerCode = Get-DenonXmlValue -Xml $PowerXml -XPath '//*[local-name()="Zone2"]/*[local-name()="Power"]'
    $sourceIndex = ConvertTo-DenonNullableInt -Value (Get-DenonXmlValue -Xml $SourceXml -XPath '//*[local-name()="Zone" and @zone="2"]/@index')
    $rawVolume = Get-DenonXmlValue -Xml $VolumeXml -XPath '//*[local-name()="Zone2"]/*[local-name()="Volume"]'
    $xmlMuteCode = Get-DenonXmlValue -Xml $VolumeXml -XPath '//*[local-name()="Zone2"]/*[local-name()="Mute"]'
    $muteCode = Get-DenonMuteCode -XmlCode $xmlMuteCode -Zone Zone2 -PreferTelnet
    $sourceName = Get-DenonSourceNameFromXml -SourceXml $SourceXml -Zone 2 -Index $sourceIndex

    [pscustomobject]@{
        IpAddress = $Receiver.IpAddress
        Power = ConvertTo-DenonPowerName -Code $powerCode
        SourceIndex = $sourceIndex
        SourceName = if ([string]::IsNullOrWhiteSpace($sourceName)) { 'Unknown' } else { $sourceName }
        VolumeRaw = ConvertTo-DenonNullableInt -Value $rawVolume
        VolumeDb = ConvertFrom-DenonRawVolume -Raw $rawVolume
        Muted = ConvertTo-DenonMuteBoolean -Code $muteCode
        MuteRaw = $muteCode
        MuteXmlRaw = $xmlMuteCode
    }
}

function Get-DenonStatus {
    <#
    .SYNOPSIS
    Read-only: Gets main zone power, source, volume, and mute state.
    #>
    [CmdletBinding()]
    param()

    $receiver = Resolve-DenonReceiver
    $powerXml = Get-DenonConfigXml -Type 4 -Receiver $receiver
    $sourceXml = Get-DenonConfigXml -Type 7 -Receiver $receiver
    $volumeXml = Get-DenonConfigXml -Type 12 -Receiver $receiver

    Get-DenonStatusFromXml -Receiver $receiver -PowerXml $powerXml -SourceXml $sourceXml -VolumeXml $volumeXml
}

function Get-DenonInfo {
    <#
    .SYNOPSIS
    Read-only: Gets receiver identity plus main and Zone 2 state.
    #>
    [CmdletBinding()]
    param()

    $receiver = Resolve-DenonReceiver
    $identityXml = Get-DenonConfigXml -Type 3 -Receiver $receiver
    $powerXml = Get-DenonConfigXml -Type 4 -Receiver $receiver
    $sourceXml = Get-DenonConfigXml -Type 7 -Receiver $receiver
    $volumeXml = Get-DenonConfigXml -Type 12 -Receiver $receiver

    $friendlyName = Get-DenonXmlValue -Xml $identityXml -XPath '//*[local-name()="FriendlyName"]'
    $manufacturer = Get-DenonXmlValue -Xml $identityXml -XPath '//*[local-name()="Manufacturer"]'
    $modelName = Get-DenonXmlValue -Xml $identityXml -XPath '//*[local-name()="ModelName"]'
    $mainStatus = Get-DenonStatusFromXml -Receiver $receiver -PowerXml $powerXml -SourceXml $sourceXml -VolumeXml $volumeXml
    $zone2Status = Get-DenonZone2StatusFromXml -Receiver $receiver -PowerXml $powerXml -SourceXml $sourceXml -VolumeXml $volumeXml

    [pscustomobject]@{
        Receiver = if ([string]::IsNullOrWhiteSpace($friendlyName)) { $receiver.Name } else { $friendlyName }
        IpAddress = $receiver.IpAddress
        Port = $receiver.Port
        Manufacturer = $manufacturer
        ModelName = $modelName
        MainZone = $mainStatus
        Zone2 = $zone2Status
    }
}

function Get-DenonHeosServiceName {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Sid,

        [AllowNull()]
        [string]$Mid
    )

    if (-not [string]::IsNullOrWhiteSpace($Mid) -and $Mid -like 'spotify:*') {
        return 'Spotify'
    }

    switch ($Sid) {
        '1' { 'Pandora'; break }
        '2' { 'Rhapsody'; break }
        '3' { 'TuneIn'; break }
        '4' { 'Spotify'; break }
        '5' { 'Deezer'; break }
        '7' { 'iHeartRadio'; break }
        '8' { 'SiriusXM'; break }
        '9' { 'SoundCloud'; break }
        '10' { 'Tidal'; break }
        '13' { 'Amazon'; break }
        '30' { 'Qobuz'; break }
        '1024' { 'Local Music'; break }
        '1025' { 'Playlists'; break }
        '1026' { 'History'; break }
        '1027' { 'AUX Input'; break }
        '1028' { 'Favorites'; break }
        default {
            if ([string]::IsNullOrWhiteSpace($Sid)) {
                return $null
            }
            return ('sid {0}' -f $Sid)
        }
    }
}

function ConvertTo-DenonTransportState {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$State
    )

    $normalized = if ($null -eq $State) { '' } else { $State.Trim().ToLowerInvariant() }
    switch ($normalized) {
        'play' { 'Playing'; break }
        'playing' { 'Playing'; break }
        'pause' { 'Paused'; break }
        'paused' { 'Paused'; break }
        'stop' { 'Stopped'; break }
        'stopped' { 'Stopped'; break }
        default {
            if ([string]::IsNullOrWhiteSpace($State)) {
                return $null
            }
            return $State
        }
    }
}

function Invoke-DenonHeosCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [psobject]$Receiver = (Resolve-DenonReceiver),

        [ValidateRange(100, 30000)]
        [int]$TimeoutMilliseconds = 1500
    )

    $client = New-Object System.Net.Sockets.TcpClient
    $async = $null
    $stream = $null
    $memory = $null
    try {
        $async = $client.BeginConnect($Receiver.IpAddress, 1255, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            throw ('Timed out connecting to HEOS CLI at {0}:1255.' -f $Receiver.IpAddress)
        }
        $client.EndConnect($async)
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMilliseconds
        $stream.WriteTimeout = $TimeoutMilliseconds

        $bytes = [System.Text.Encoding]::ASCII.GetBytes(('{0}{1}' -f $Command, "`r`n"))
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()

        $buffer = New-Object byte[] 4096
        $memory = New-Object System.IO.MemoryStream
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $lastDataAtMilliseconds = $null
        while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            if ($stream.DataAvailable) {
                do {
                    $read = $stream.Read($buffer, 0, $buffer.Length)
                    if ($read -gt 0) {
                        $memory.Write($buffer, 0, $read)
                        $lastDataAtMilliseconds = $stopwatch.ElapsedMilliseconds
                    }
                } while ($stream.DataAvailable)
            }
            elseif ($null -ne $lastDataAtMilliseconds -and ($stopwatch.ElapsedMilliseconds - $lastDataAtMilliseconds) -ge 100) {
                break
            }
            else {
                Start-Sleep -Milliseconds 25
            }
        }

        $text = [System.Text.Encoding]::UTF8.GetString($memory.ToArray()).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }
        $text | ConvertFrom-Json
    }
    catch {
        Write-Verbose ('HEOS command failed: {0}' -f $_.Exception.Message)
        return $null
    }
    finally {
        if ($null -ne $memory) { $memory.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $async -and $null -ne $async.AsyncWaitHandle) { $async.AsyncWaitHandle.Dispose() }
        if ($null -ne $client) { $client.Close() }
    }
}

function Get-DenonNowPlaying {
    <#
    .SYNOPSIS
    Read-only: Gets current network/HEOS now-playing metadata when available.
    #>
    [CmdletBinding()]
    param()

    $receiver = Resolve-DenonReceiver
    $title = $null
    $artist = $null
    $album = $null
    $station = $null
    $service = $null
    $state = $null
    $playerId = $null
    $heosModel = $null
    $heosVersion = $null
    $network = $null
    $source = 'Unavailable'

    foreach ($port in @(80, 8080)) {
        try {
            $xmlText = Invoke-DenonPlainHttpGet -Path '/goform/formNetAudio_StatusXml.xml' -Port $port -Receiver $receiver
            if ($xmlText -match '<') {
                $xml = ConvertTo-DenonXmlDocument -XmlText $xmlText
                $title = Get-DenonXmlValue -Xml $xml -XPath '//*[local-name()="Song" or local-name()="szLine1"]'
                $artist = Get-DenonXmlValue -Xml $xml -XPath '//*[local-name()="Artist" or local-name()="szLine2"]'
                $album = Get-DenonXmlValue -Xml $xml -XPath '//*[local-name()="Album" or local-name()="szLine3"]'
                $source = 'NetAudioStatusXml'
                break
            }
        }
        catch {
            Write-Verbose ('now-playing XML port {0} unavailable: {1}' -f $port, $_.Exception.Message)
        }
    }

    $players = Invoke-DenonHeosCommand -Command 'heos://player/get_players' -Receiver $receiver
    if ($null -ne $players -and $players.heos.result -eq 'success' -and $players.payload.Count -gt 0) {
        $player = @($players.payload)[0]
        $playerId = [string]$player.pid
        if (-not (Test-DenonHeosPlayerId -PlayerId $playerId)) {
            Write-Verbose ('Ignoring invalid HEOS player id from receiver: {0}' -f $playerId)
            $playerId = $null
        }
        $heosModel = [string]$player.model
        $heosVersion = [string]$player.version
        $network = [string]$player.network
        if ([string]::IsNullOrWhiteSpace($service) -and -not [string]::IsNullOrWhiteSpace([string]$player.name)) {
            $service = [string]$player.name
        }

        if (-not [string]::IsNullOrWhiteSpace($playerId)) {
            $media = Invoke-DenonHeosCommand -Command ('heos://player/get_now_playing_media?pid={0}' -f $playerId) -Receiver $receiver
            if ($null -ne $media -and $media.heos.result -eq 'success') {
                if ([string]::IsNullOrWhiteSpace($title)) { $title = [string]$media.payload.song }
                if ([string]::IsNullOrWhiteSpace($artist)) { $artist = [string]$media.payload.artist }
                if ([string]::IsNullOrWhiteSpace($album)) { $album = [string]$media.payload.album }
                $station = [string]$media.payload.station
                $serviceName = Get-DenonHeosServiceName -Sid ([string]$media.payload.sid) -Mid ([string]$media.payload.mid)
                if (-not [string]::IsNullOrWhiteSpace($serviceName)) { $service = $serviceName }
                $source = if ($source -eq 'Unavailable') { 'HEOS' } else { '{0}+HEOS' -f $source }
            }

            $playState = Invoke-DenonHeosCommand -Command ('heos://player/get_play_state?pid={0}' -f $playerId) -Receiver $receiver
            if ($null -ne $playState -and $playState.heos.result -eq 'success') {
                $message = [string]$playState.heos.message
                if ($message -match '(?:^|[?&])state=([^&]+)') {
                    $state = ConvertTo-DenonTransportState -State ([System.Uri]::UnescapeDataString($Matches[1]))
                }
            }
        }
    }

    [pscustomobject]@{
        IpAddress = $receiver.IpAddress
        Title = if ([string]::IsNullOrWhiteSpace($title)) { $null } else { $title }
        Artist = if ([string]::IsNullOrWhiteSpace($artist)) { $null } else { $artist }
        Album = if ([string]::IsNullOrWhiteSpace($album)) { $null } else { $album }
        Station = if ([string]::IsNullOrWhiteSpace($station)) { $null } else { $station }
        Service = if ([string]::IsNullOrWhiteSpace($service)) { $null } else { $service }
        State = $state
        PlayerId = if ([string]::IsNullOrWhiteSpace($playerId)) { $null } else { $playerId }
        HeosModel = if ([string]::IsNullOrWhiteSpace($heosModel)) { $null } else { $heosModel }
        HeosVersion = if ([string]::IsNullOrWhiteSpace($heosVersion)) { $null } else { $heosVersion }
        Network = if ([string]::IsNullOrWhiteSpace($network)) { $null } else { $network }
        Source = $source
    }
}

function Get-DenonReceiverSummary {
    <#
    .SYNOPSIS
    Read-only: Gets concise receiver diagnostics from safe read-only surfaces.
    #>
    [CmdletBinding()]
    param()

    $receiver = Resolve-DenonReceiver
    $type1Xml = Get-DenonOptionalConfigXml -Type 1 -Receiver $receiver
    $identityXml = Get-DenonOptionalConfigXml -Type 3 -Receiver $receiver
    $modelTypeXml = Get-DenonOptionalConfigXml -Type 5 -Receiver $receiver
    $zoneNameXml = Get-DenonOptionalConfigXml -Type 6 -Receiver $receiver
    $volumeXml = Get-DenonOptionalConfigXml -Type 12 -Receiver $receiver
    $setupLockXml = Get-DenonOptionalConfigXml -Type 8 -Receiver $receiver
    $btXml = Get-DenonOptionalConfigXml -Type 9 -Receiver $receiver
    $speakerPresetXml = Get-DenonOptionalConfigXml -Type 10 -Receiver $receiver
    $systemXml = Get-DenonOptionalConfigXml -Type 11 -Receiver $receiver
    $nowPlaying = Get-DenonNowPlaying

    $mainMaxRaw = if ($null -ne $volumeXml) { Get-DenonXmlValue -Xml $volumeXml -XPath '//*[local-name()="MainZone"]/*[local-name()="Max"]' } else { $null }

    [pscustomobject]@{
        Receiver = [pscustomobject]@{
            Name = if ($null -ne $identityXml) { Get-DenonXmlValue -Xml $identityXml -XPath '//*[local-name()="FriendlyName"]' } else { $null }
            IpAddress = $receiver.IpAddress
            BrandCode = if ($null -ne $type1Xml) { Get-DenonXmlValue -Xml $type1Xml -XPath '//*[local-name()="Brand"]' } else { $null }
            ModelType = if ($null -ne $modelTypeXml) { Get-DenonXmlValue -Xml $modelTypeXml -XPath '//*[local-name()="ModelType"]' } else { $null }
        }
        Volume = [pscustomobject]@{
            MainZone = [pscustomobject]@{
                ZoneName = if ($null -ne $zoneNameXml) { Get-DenonXmlValue -Xml $zoneNameXml -XPath '//*[local-name()="MainZone"]' } else { $null }
                VolumeScale = if ($null -ne $volumeXml) { Get-DenonXmlValue -Xml $volumeXml -XPath '//*[local-name()="MainZone"]/*[local-name()="VolumeScale"]' } else { $null }
                VolumeLimitRaw = if ($null -ne $volumeXml) { Get-DenonXmlValue -Xml $volumeXml -XPath '//*[local-name()="MainZone"]/*[local-name()="VolumeLimit"]' } else { $null }
                VolumeMaxDb = ConvertFrom-DenonRawVolume -Raw $mainMaxRaw
            }
            Zone2 = [pscustomobject]@{
                ZoneName = if ($null -ne $zoneNameXml) { Get-DenonXmlValue -Xml $zoneNameXml -XPath '//*[local-name()="Zone2"]' } else { $null }
                VolumeScale = if ($null -ne $volumeXml) { Get-DenonXmlValue -Xml $volumeXml -XPath '//*[local-name()="Zone2"]/*[local-name()="VolumeScale"]' } else { $null }
                VolumeLimitRaw = if ($null -ne $volumeXml) { Get-DenonXmlValue -Xml $volumeXml -XPath '//*[local-name()="Zone2"]/*[local-name()="VolumeLimit"]' } else { $null }
            }
        }
        System = [pscustomobject]@{
            SetupLock = if ($null -ne $setupLockXml) { Get-DenonXmlValue -Xml $setupLockXml -XPath '//*[local-name()="SetupLock"]' } else { $null }
            MenuLock = if ($null -ne $systemXml) { Get-DenonXmlValue -Xml $systemXml -XPath '//*[local-name()="System"]/*[local-name()="MenuLock"]' } else { $null }
            AdvancedMode = if ($null -ne $systemXml) { Get-DenonXmlValue -Xml $systemXml -XPath '//*[local-name()="System"]/*[local-name()="AdvancedMode"]' } else { $null }
            CiMode = if ($null -ne $systemXml) { Get-DenonXmlValue -Xml $systemXml -XPath '//*[local-name()="System"]/*[local-name()="CIMode"]' } else { $null }
            SpeakerPreset = if ($null -ne $speakerPresetXml) { Get-DenonXmlValue -Xml $speakerPresetXml -XPath '//*[local-name()="SpeakerPreset"]' } else { $null }
            GuiType = if ($null -ne $systemXml) { Get-DenonXmlValue -Xml $systemXml -XPath '//*[local-name()="System"]/*[local-name()="GuiType"]' } else { $null }
            WebUiType = if ($null -ne $systemXml) { Get-DenonXmlValue -Xml $systemXml -XPath '//*[local-name()="System"]/*[local-name()="WebUIType"]' } else { $null }
            ProductType = if ($null -ne $systemXml) { Get-DenonXmlValue -Xml $systemXml -XPath '//*[local-name()="System"]/*[local-name()="ProductType"]' } else { $null }
            BluetoothHeadphonesSingleUsed = if ($null -ne $btXml) { Get-DenonXmlValue -Xml $btXml -XPath '//*[local-name()="BtHeadphonesSingleUsed"]' } else { $null }
            HeosSignIn = if ($null -ne $systemXml) { Get-DenonXmlValue -Xml $systemXml -XPath '//*[local-name()="System"]/*[local-name()="HEOSSignIn"]' } else { $null }
        }
        NowPlaying = $nowPlaying
        Firmware = [pscustomobject]@{
            AvrMainboardFirmware = $null
            AvrMainboardFirmwareNote = 'unavailable on tested read-only surfaces'
            HeosVersion = $nowPlaying.HeosVersion
        }
        ToolVersion = $script:DenonControllerVersion
    }
}

function Get-DenonSources {
    <#
    .SYNOPSIS
    Read-only: Lists receiver sources for the main zone or Zone 2.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet(1, 2)]
        [int]$Zone = 1
    )

    $receiver = Resolve-DenonReceiver
    $sourceXml = Get-DenonConfigXml -Type 7 -Receiver $receiver
    $sources = @(Get-DenonSourceRowsFromXml -SourceXml $sourceXml -Zone $Zone)
    if ($sources.Count -eq 0) {
        Write-Error ('Could not read source list for zone {0}.' -f $Zone)
        return
    }

    $sources
}

function Get-DenonZone2Status {
    <#
    .SYNOPSIS
    Read-only: Gets Zone 2 power, source, volume, and mute state.
    #>
    [CmdletBinding()]
    param()

    $receiver = Resolve-DenonReceiver
    $powerXml = Get-DenonConfigXml -Type 4 -Receiver $receiver
    $sourceXml = Get-DenonConfigXml -Type 7 -Receiver $receiver
    $volumeXml = Get-DenonConfigXml -Type 12 -Receiver $receiver

    Get-DenonZone2StatusFromXml -Receiver $receiver -PowerXml $powerXml -SourceXml $sourceXml -VolumeXml $volumeXml
}

function Test-DenonReceiver {
    <#
    .SYNOPSIS
    Read-only: Tests whether the configured receiver responds to Denon XML endpoints.
    #>
    [CmdletBinding()]
    param()

    $receiver = Resolve-DenonReceiver
    try {
        $identityXml = Get-DenonConfigXml -Type 3 -Receiver $receiver
        $powerXml = Get-DenonConfigXml -Type 4 -Receiver $receiver
        $identityText = $identityXml.OuterXml
        $friendlyName = Get-DenonXmlValue -Xml $identityXml -XPath '//*[local-name()="FriendlyName"]'
        $powerCode = Get-DenonXmlValue -Xml $powerXml -XPath '//*[local-name()="MainZone"]/*[local-name()="Power"]'

        [pscustomobject]@{
            IpAddress = $receiver.IpAddress
            Port = $receiver.Port
            Responded = $true
            IsDenon = ($identityText -match 'Denon')
            Receiver = $friendlyName
            MainPower = ConvertTo-DenonPowerName -Code $powerCode
            Error = $null
        }
    }
    catch {
        [pscustomobject]@{
            IpAddress = $receiver.IpAddress
            Port = $receiver.Port
            Responded = $false
            IsDenon = $false
            Receiver = $null
            MainPower = $null
            Error = $_.Exception.Message
        }
    }
}

function Invoke-DenonTelnetCommand {
    <#
    .SYNOPSIS
    Sends a single Denon telnet-style command over a native TCP socket.

    .DESCRIPTION
    Advanced helper. Some commands change AVR state. Use read-only queries such
    as SLP? when you only want status.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [switch]$ReadResponse,

        [ValidateRange(100, 30000)]
        [int]$TimeoutMilliseconds = 2000,

        [string]$IpAddress,

        [ValidateRange(1, 65535)]
        [int]$Port
    )

    $receiver = Resolve-DenonReceiver
    if (-not [string]::IsNullOrWhiteSpace($IpAddress)) {
        $receiver.IpAddress = $IpAddress
    }
    if ($Port -gt 0) {
        $receiver.TelnetPort = $Port
    }

    Write-Verbose ('TCP {0}:{1} {2}' -f $receiver.IpAddress, $receiver.TelnetPort, $Command)

    $client = New-Object System.Net.Sockets.TcpClient
    $async = $null
    $stream = $null
    $memory = $null
    try {
        $async = $client.BeginConnect($receiver.IpAddress, $receiver.TelnetPort, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            throw ('Timed out connecting to {0}:{1}.' -f $receiver.IpAddress, $receiver.TelnetPort)
        }
        $client.EndConnect($async)

        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMilliseconds
        $stream.WriteTimeout = $TimeoutMilliseconds

        $bytes = [System.Text.Encoding]::ASCII.GetBytes(('{0}{1}' -f $Command, "`r"))
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()

        if (-not $ReadResponse) {
            return [pscustomobject]@{
                IpAddress = $receiver.IpAddress
                Port = $receiver.TelnetPort
                Command = $Command
                Response = $null
                ReceivedResponse = $null
                Sent = $true
            }
        }

        $buffer = New-Object byte[] 1024
        $memory = New-Object System.IO.MemoryStream
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $quietPeriodMilliseconds = 75
        $lastDataAtMilliseconds = $null

        while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            if ($stream.DataAvailable) {
                do {
                    $read = $stream.Read($buffer, 0, $buffer.Length)
                    if ($read -gt 0) {
                        $memory.Write($buffer, 0, $read)
                        $lastDataAtMilliseconds = $stopwatch.ElapsedMilliseconds
                    }
                } while ($stream.DataAvailable)
            }
            elseif ($null -ne $lastDataAtMilliseconds -and
                ($stopwatch.ElapsedMilliseconds - $lastDataAtMilliseconds) -ge $quietPeriodMilliseconds) {
                break
            }
            else {
                Start-Sleep -Milliseconds 25
            }
        }

        $response = [System.Text.Encoding]::ASCII.GetString($memory.ToArray())
        $receivedResponse = -not [string]::IsNullOrWhiteSpace($response)
        [pscustomobject]@{
            IpAddress = $receiver.IpAddress
            Port = $receiver.TelnetPort
            Command = $Command
            Response = $response
            ReceivedResponse = $receivedResponse
            Sent = $true
        }
    }
    catch {
        throw ('Denon TCP command failed: {0}' -f $_.Exception.Message)
    }
    finally {
        if ($null -ne $memory) {
            $memory.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if ($null -ne $async -and $null -ne $async.AsyncWaitHandle) {
            $async.AsyncWaitHandle.Dispose()
        }
        if ($null -ne $client) {
            $client.Close()
        }
    }
}

function Get-DenonSleep {
    <#
    .SYNOPSIS
    Read-only: Gets the sleep timer using the Denon TCP command interface.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet(1, 2, 3)]
        [int]$Zone = 1
    )

    $prefix = ''
    $zoneName = 'Main'
    if ($Zone -eq 2) {
        $prefix = 'Z2'
        $zoneName = 'Zone 2'
    }
    elseif ($Zone -eq 3) {
        $prefix = 'Z3'
        $zoneName = 'Zone 3'
    }

    $command = '{0}SLP?' -f $prefix
    $result = Invoke-DenonTelnetCommand -Command $command -ReadResponse
    $lines = @($result.Response -split "`r`n|`n|`r" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $line = $null
    foreach ($candidate in $lines) {
        if ($candidate -like ('{0}SLP*' -f $prefix)) {
            $line = $candidate.Trim()
            break
        }
    }

    $minutes = $null
    $state = 'unknown'
    $errorMessage = $null
    if (-not $result.ReceivedResponse) {
        $errorMessage = 'No sleep timer response was received before the TCP timeout.'
    }
    elseif ($line -eq ('{0}SLPOFF' -f $prefix)) {
        $state = 'off'
    }
    elseif ($line -match ('^{0}SLP([0-9]{{3}})$' -f [regex]::Escape($prefix))) {
        $minutes = [int]$Matches[1]
        $state = 'on'
    }
    else {
        $errorMessage = 'Sleep timer response was not recognized.'
    }

    [pscustomobject]@{
        IpAddress = $result.IpAddress
        Zone = $Zone
        ZoneName = $zoneName
        State = $state
        Minutes = $minutes
        RawResponse = $line
        Error = $errorMessage
    }
}

function New-DenonSetResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Receiver,

        [Parameter(Mandatory = $true)]
        [string]$Zone,

        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [hashtable]$Values
    )

    $result = [ordered]@{
        IpAddress = $Receiver.IpAddress
        Zone = $Zone
        Action = $Action
        Changed = $true
    }

    foreach ($key in $Values.Keys) {
        $result[$key] = $Values[$key]
    }

    [pscustomobject]$result
}

function Set-DenonPower {
    <#
    .SYNOPSIS
    State-changing: Turns main zone power on or off.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'On')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'On')]
        [switch]$On,

        [Parameter(Mandatory = $true, ParameterSetName = 'Off')]
        [switch]$Off
    )

    $receiver = Resolve-DenonReceiver
    $code = if ($PSCmdlet.ParameterSetName -eq 'On') { '1' } else { '3' }
    $state = if ($code -eq '1') { 'ON' } else { 'OFF' }
    $payload = '<MainZone><Power>{0}</Power></MainZone>' -f $code

    if ($PSCmdlet.ShouldProcess($receiver.IpAddress, ('set main zone power {0}' -f $state))) {
        Invoke-DenonSetConfig -Type 4 -Data $payload -Receiver $receiver
        New-DenonSetResult -Receiver $receiver -Zone 'Main' -Action 'Power' -Values @{ Power = $state; PowerCode = $code }
    }
}

function Set-DenonMute {
    <#
    .SYNOPSIS
    State-changing: Turns main zone mute on or off.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'On')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'On')]
        [switch]$On,

        [Parameter(Mandatory = $true, ParameterSetName = 'Off')]
        [switch]$Off
    )

    $receiver = Resolve-DenonReceiver
    $code = if ($PSCmdlet.ParameterSetName -eq 'On') { '1' } else { '2' }
    $muted = $code -eq '1'
    $payload = '<MainZone><Mute>{0}</Mute></MainZone>' -f $code

    if ($PSCmdlet.ShouldProcess($receiver.IpAddress, ('set main zone mute {0}' -f $muted))) {
        Invoke-DenonSetConfig -Type 12 -Data $payload -Receiver $receiver
        New-DenonSetResult -Receiver $receiver -Zone 'Main' -Action 'Mute' -Values @{ Muted = $muted; MuteCode = $code }
    }
}

function Set-DenonVolume {
    <#
    .SYNOPSIS
    State-changing: Sets main zone volume in dB.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [double]$Db,

        [switch]$AllowAboveMaxVolume
    )

    $receiver = Resolve-DenonReceiver
    Assert-DenonVolumeWithinMax -Db $Db -AllowAboveMaxVolume:$AllowAboveMaxVolume.IsPresent
    $raw = ConvertTo-DenonRawVolume -Db $Db
    $payload = '<MainZone><Volume>{0}</Volume></MainZone>' -f $raw

    if ($PSCmdlet.ShouldProcess($receiver.IpAddress, ('set main zone volume to {0} dB' -f $Db))) {
        Invoke-DenonSetConfig -Type 12 -Data $payload -Receiver $receiver
        New-DenonSetResult -Receiver $receiver -Zone 'Main' -Action 'Volume' -Values @{ VolumeDb = [double]$Db; VolumeRaw = $raw }
    }
}

function Step-DenonVolume {
    <#
    .SYNOPSIS
    State-changing: Adjusts main zone volume by a relative dB amount.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [double]$Db,

        [switch]$AllowAboveMaxVolume
    )

    $receiver = Resolve-DenonReceiver
    $volumeXml = Get-DenonConfigXml -Type 12 -Receiver $receiver
    $rawVolume = Get-DenonXmlValue -Xml $volumeXml -XPath '//*[local-name()="MainZone"]/*[local-name()="Volume"]'
    if ([string]::IsNullOrWhiteSpace($rawVolume)) {
        throw 'Could not read current main zone volume.'
    }

    $currentDb = ConvertFrom-DenonRawVolume -Raw $rawVolume
    $targetDb = [Math]::Round(([double]$currentDb + $Db), 1)
    Assert-DenonVolumeWithinMax -Db $targetDb -AllowAboveMaxVolume:$AllowAboveMaxVolume.IsPresent
    $targetRaw = ConvertTo-DenonRawVolume -Db $targetDb
    $payload = '<MainZone><Volume>{0}</Volume></MainZone>' -f $targetRaw

    if ($PSCmdlet.ShouldProcess($receiver.IpAddress, ('step main zone volume by {0} dB to {1} dB' -f $Db, $targetDb))) {
        Invoke-DenonSetConfig -Type 12 -Data $payload -Receiver $receiver
        New-DenonSetResult -Receiver $receiver -Zone 'Main' -Action 'StepVolume' -Values @{
            PreviousVolumeDb = $currentDb
            DeltaDb = [double]$Db
            VolumeDb = $targetDb
            VolumeRaw = $targetRaw
        }
    }
}

function Resolve-DenonSourceIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [xml]$SourceXml,

        [Parameter(Mandatory = $true)]
        [ValidateSet(1, 2)]
        [int]$Zone,

        [int]$Index,

        [string]$Name
    )

    $sources = @(Get-DenonSourceRowsFromXml -SourceXml $SourceXml -Zone $Zone)
    if ($sources.Count -eq 0) {
        throw ('Could not read source list for zone {0}.' -f $Zone)
    }

    if ($PSBoundParameters.ContainsKey('Index')) {
        foreach ($source in $sources) {
            if ($source.Index -eq $Index) {
                return $source
            }
        }
        throw ('Unknown source index {0} for zone {1}.' -f $Index, $Zone)
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw ('Source name is required for zone {0}.' -f $Zone)
    }

    $wanted = ConvertTo-DenonSourceKey -Value $Name
    foreach ($source in $sources) {
        if ((ConvertTo-DenonSourceKey -Value $source.ReceiverName) -eq $wanted -or
            (ConvertTo-DenonSourceKey -Value $source.DisplayName) -eq $wanted) {
            return $source
        }
    }

    foreach ($source in $sources) {
        if ((ConvertTo-DenonSourceKey -Value $source.ReceiverName).Contains($wanted) -or
            (ConvertTo-DenonSourceKey -Value $source.DisplayName).Contains($wanted)) {
            return $source
        }
    }

    throw ('Unknown source "{0}" for zone {1}.' -f $Name, $Zone)
}

function Set-DenonSource {
    <#
    .SYNOPSIS
    State-changing: Sets the main zone source by receiver index or name.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'ByIndex')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ByIndex')]
        [int]$Index,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
        [string]$Name
    )

    $receiver = Resolve-DenonReceiver
    $sourceXml = Get-DenonConfigXml -Type 7 -Receiver $receiver
    if ($PSCmdlet.ParameterSetName -eq 'ByIndex') {
        $source = Resolve-DenonSourceIndex -SourceXml $sourceXml -Zone 1 -Index $Index
    }
    else {
        $source = Resolve-DenonSourceIndex -SourceXml $sourceXml -Zone 1 -Name $Name
    }

    $payload = '<Source zone="1" index="{0}"></Source>' -f $source.Index
    if ($PSCmdlet.ShouldProcess($receiver.IpAddress, ('set main zone source to {0} ({1})' -f $source.DisplayName, $source.Index))) {
        Invoke-DenonSetConfig -Type 7 -Data $payload -Receiver $receiver
        New-DenonSetResult -Receiver $receiver -Zone 'Main' -Action 'Source' -Values @{
            SourceIndex = $source.Index
            SourceName = $source.DisplayName
        }
    }
}

function Set-DenonZone2Source {
    <#
    .SYNOPSIS
    State-changing: Sets the Zone 2 source by receiver index or name.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'ByIndex')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ByIndex')]
        [int]$Index,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
        [string]$Name
    )

    $receiver = Resolve-DenonReceiver
    $sourceXml = Get-DenonConfigXml -Type 7 -Receiver $receiver
    if ($PSCmdlet.ParameterSetName -eq 'ByIndex') {
        $source = Resolve-DenonSourceIndex -SourceXml $sourceXml -Zone 2 -Index $Index
    }
    else {
        $source = Resolve-DenonSourceIndex -SourceXml $sourceXml -Zone 2 -Name $Name
    }

    $payload = '<Source zone="2" index="{0}"></Source>' -f $source.Index
    if ($PSCmdlet.ShouldProcess($receiver.IpAddress, ('set Zone 2 source to {0} ({1})' -f $source.DisplayName, $source.Index))) {
        Invoke-DenonSetConfig -Type 7 -Data $payload -Receiver $receiver
        New-DenonSetResult -Receiver $receiver -Zone 'Zone2' -Action 'Source' -Values @{
            SourceIndex = $source.Index
            SourceName = $source.DisplayName
        }
    }
}

function Set-DenonZone2Power {
    <#
    .SYNOPSIS
    State-changing: Turns Zone 2 power on or off.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'On')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'On')]
        [switch]$On,

        [Parameter(Mandatory = $true, ParameterSetName = 'Off')]
        [switch]$Off
    )

    $receiver = Resolve-DenonReceiver
    $code = if ($PSCmdlet.ParameterSetName -eq 'On') { '1' } else { '3' }
    $state = if ($code -eq '1') { 'ON' } else { 'OFF' }
    $payload = '<Zone2><Power>{0}</Power></Zone2>' -f $code

    if ($PSCmdlet.ShouldProcess($receiver.IpAddress, ('set Zone 2 power {0}' -f $state))) {
        Invoke-DenonSetConfig -Type 4 -Data $payload -Receiver $receiver
        New-DenonSetResult -Receiver $receiver -Zone 'Zone2' -Action 'Power' -Values @{ Power = $state; PowerCode = $code }
    }
}

function Set-DenonZone2Mute {
    <#
    .SYNOPSIS
    State-changing: Turns Zone 2 mute on or off.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'On')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'On')]
        [switch]$On,

        [Parameter(Mandatory = $true, ParameterSetName = 'Off')]
        [switch]$Off
    )

    $receiver = Resolve-DenonReceiver
    $code = if ($PSCmdlet.ParameterSetName -eq 'On') { '1' } else { '2' }
    $muted = $code -eq '1'
    $payload = '<Zone2><Mute>{0}</Mute></Zone2>' -f $code

    if ($PSCmdlet.ShouldProcess($receiver.IpAddress, ('set Zone 2 mute {0}' -f $muted))) {
        Invoke-DenonSetConfig -Type 12 -Data $payload -Receiver $receiver
        New-DenonSetResult -Receiver $receiver -Zone 'Zone2' -Action 'Mute' -Values @{ Muted = $muted; MuteCode = $code }
    }
}

function Set-DenonZone2Volume {
    <#
    .SYNOPSIS
    State-changing: Sets Zone 2 raw volume.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 980)]
        [int]$Raw,

        [switch]$AllowAboveMaxVolume
    )

    $receiver = Resolve-DenonReceiver
    $targetDb = ConvertFrom-DenonRawVolume -Raw ([string]$Raw)
    Assert-DenonVolumeWithinMax -Db $targetDb -AllowAboveMaxVolume:$AllowAboveMaxVolume.IsPresent
    $payload = '<Zone2><Volume>{0}</Volume></Zone2>' -f $Raw

    if ($PSCmdlet.ShouldProcess($receiver.IpAddress, ('set Zone 2 raw volume to {0}' -f $Raw))) {
        Invoke-DenonSetConfig -Type 12 -Data $payload -Receiver $receiver
        New-DenonSetResult -Receiver $receiver -Zone 'Zone2' -Action 'Volume' -Values @{
            VolumeRaw = $Raw
            VolumeDb = $targetDb
        }
    }
}

function Step-DenonZone2Volume {
    <#
    .SYNOPSIS
    State-changing: Adjusts Zone 2 volume by a relative dB amount.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [double]$Db,

        [switch]$AllowAboveMaxVolume
    )

    $receiver = Resolve-DenonReceiver
    $volumeXml = Get-DenonConfigXml -Type 12 -Receiver $receiver
    $rawVolume = Get-DenonXmlValue -Xml $volumeXml -XPath '//*[local-name()="Zone2"]/*[local-name()="Volume"]'
    if ([string]::IsNullOrWhiteSpace($rawVolume)) {
        throw 'Could not read current Zone 2 volume.'
    }

    $currentDb = ConvertFrom-DenonRawVolume -Raw $rawVolume
    $targetDb = [Math]::Round(([double]$currentDb + $Db), 1)
    Assert-DenonVolumeWithinMax -Db $targetDb -AllowAboveMaxVolume:$AllowAboveMaxVolume.IsPresent
    $targetRaw = ConvertTo-DenonRawVolume -Db $targetDb
    $payload = '<Zone2><Volume>{0}</Volume></Zone2>' -f $targetRaw

    if ($PSCmdlet.ShouldProcess($receiver.IpAddress, ('step Zone 2 volume by {0} dB to raw {1}' -f $Db, $targetRaw))) {
        Invoke-DenonSetConfig -Type 12 -Data $payload -Receiver $receiver
        New-DenonSetResult -Receiver $receiver -Zone 'Zone2' -Action 'StepVolume' -Values @{
            PreviousVolumeDb = $currentDb
            DeltaDb = [double]$Db
            VolumeDb = $targetDb
            VolumeRaw = $targetRaw
        }
    }
}

function Set-DenonReceiverIp {
    <#
    .SYNOPSIS
    Stores the receiver IP in the shared Denon cache, matching denon setip.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidatePattern('^[0-9]{1,3}(\.[0-9]{1,3}){3}$')]
        [string]$IpAddress
    )

    $cachePath = Get-DenonPlatformPath -Kind Cache
    $directory = Split-Path -Parent $cachePath
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Set-Content -LiteralPath $cachePath -Value $IpAddress -NoNewline -Encoding ascii
    $script:DenonReceiverConfig.IpAddress = $IpAddress
    [pscustomobject]@{
        IpAddress = $IpAddress
        CachePath = $cachePath
        Saved = $true
    }
}

function Find-DenonReceiver {
    <#
    .SYNOPSIS
    Finds a receiver using the PowerShell parity of DENON_IP, cache, DENON_DEFAULT_IP, and SSDP.
    #>
    [CmdletBinding()]
    param(
        [switch]$RefreshCache
    )

    if ($RefreshCache.IsPresent) {
        $cachePath = Get-DenonPlatformPath -Kind Cache
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    }

    foreach ($candidate in @(
            (Get-DenonConfiguredValue -Name 'DENON_IP'),
            $(if (Test-Path -LiteralPath (Get-DenonPlatformPath -Kind Cache) -PathType Leaf) { (Get-Content -LiteralPath (Get-DenonPlatformPath -Kind Cache) -Raw).Trim() }),
            (Get-DenonConfiguredValue -Name 'DENON_DEFAULT_IP')
        )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        Set-DenonReceiver -IpAddress $candidate | Out-Null
        $test = Test-DenonReceiver
        if ($test.Responded -and $test.IsDenon) {
            Set-DenonReceiverIp -IpAddress $candidate
            return $test
        }
    }

    $timeout = Get-DenonConfiguredValue -Name 'DENON_SSDP_TIMEOUT'
    $timeoutMs = 2000
    if (-not [string]::IsNullOrWhiteSpace($timeout)) {
        $parsed = 0.0
        if ([double]::TryParse($timeout, [ref]$parsed) -and $parsed -gt 0) {
            $timeoutMs = [int]($parsed * 1000)
        }
    }

    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $timeoutMs
        $endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse('239.255.255.250'), 1900)
        $mx = Get-DenonConfiguredValue -Name 'DENON_SSDP_MX'
        if ([string]::IsNullOrWhiteSpace($mx)) { $mx = '1' }
        $message = "M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`nMAN: `"ssdp:discover`"`r`nMX: $mx`r`nST: urn:schemas-upnp-org:device:MediaRenderer:1`r`n`r`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($message)
        [void]$udp.Send($bytes, $bytes.Length, $endpoint)
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $started = [DateTime]::UtcNow
        while (([DateTime]::UtcNow - $started).TotalMilliseconds -lt $timeoutMs) {
            $responseBytes = $udp.Receive([ref]$remote)
            $response = [System.Text.Encoding]::ASCII.GetString($responseBytes)
            if ($response -match '(?im)^LOCATION:\s*https?://([0-9.]+)[:/]') {
                $candidate = $Matches[1]
                Set-DenonReceiver -IpAddress $candidate | Out-Null
                $test = Test-DenonReceiver
                if ($test.Responded -and $test.IsDenon) {
                    Set-DenonReceiverIp -IpAddress $candidate
                    return $test
                }
            }
        }
    }
    catch {
        Write-Verbose ('SSDP discovery failed: {0}' -f $_.Exception.Message)
    }
    finally {
        if ($null -ne $udp) { $udp.Dispose() }
    }

    throw 'No Denon receiver found.'
}

function Get-DenonRawConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateRange(0, 99)]
        [int]$Type
    )

    $receiver = Resolve-DenonReceiver
    $uri = '{0}/ajax/globals/get_config?type={1}' -f $receiver.BaseUri, $Type
    Invoke-DenonHttpGet -Uri $uri -TimeoutSeconds $receiver.TimeoutSeconds -SkipCertificateCheck $receiver.SkipCertificateCheck -CaCert $receiver.CaCert -PinnedPublicKey $receiver.PinnedPublicKey
}

function Set-DenonRawConfig {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateRange(0, 99)]
        [int]$Type,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Xml
    )

    $receiver = Resolve-DenonReceiver
    if ($PSCmdlet.ShouldProcess($receiver.IpAddress, ('set_config type {0}' -f $Type))) {
        $encodedData = ConvertTo-DenonQueryValue -Value $Xml
        $uri = '{0}/ajax/globals/set_config?type={1}&data={2}' -f $receiver.BaseUri, $Type, $encodedData
        Invoke-DenonHttpGet -Uri $uri -TimeoutSeconds $receiver.TimeoutSeconds -SkipCertificateCheck $receiver.SkipCertificateCheck -CaCert $receiver.CaCert -PinnedPublicKey $receiver.PinnedPublicKey | Out-Null
        [pscustomobject]@{ IpAddress = $receiver.IpAddress; Type = $Type; Sent = $true }
    }
}

function Get-DenonRawStatus {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        PowerXml = Get-DenonRawConfig -Type 4
        SourceXml = Get-DenonRawConfig -Type 7
        VolumeXml = Get-DenonRawConfig -Type 12
    }
}

function Set-DenonSleep {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Position = 0)]
        [ValidateSet(1, 2, 3)]
        [int]$Zone = 1,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowNull()]
        [string]$Value
    )

    $prefix = if ($Zone -eq 2) { 'Z2' } elseif ($Zone -eq 3) { 'Z3' } else { '' }
    $code = $null
    if ($Value -match '^(?i:off|clear|0)$') {
        $code = '{0}SLPOFF' -f $prefix
    }
    else {
        $minutes = 0
        if (-not [int]::TryParse($Value, [ref]$minutes) -or $minutes -lt 1 -or $minutes -gt 120) {
            throw 'Sleep timer must be off or 1-120 minutes.'
        }
        $code = '{0}SLP{1:000}' -f $prefix, $minutes
    }

    if ($PSCmdlet.ShouldProcess((Resolve-DenonReceiver).IpAddress, ('sleep {0}' -f $code))) {
        Invoke-DenonTelnetCommand -Command $code | Out-Null
        Get-DenonSleep -Zone $Zone
    }
}

function Invoke-DenonQuickSelect {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateRange(1, 5)]
        [int]$Number,

        [switch]$Save
    )

    $command = if ($Save.IsPresent) { 'QUICK{0} MEMORY' -f $Number } else { 'QUICK{0}' -f $Number }
    $action = if ($Save.IsPresent) { 'Stored' } else { 'Recalled' }
    if ($PSCmdlet.ShouldProcess((Resolve-DenonReceiver).IpAddress, $command)) {
        Invoke-DenonTelnetCommand -Command $command | Out-Null
        [pscustomobject]@{ QuickSelect = $Number; Action = $action }
    }
}

function Set-DenonSoundMode {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('stereo', 'direct', 'pure', 'pure-direct', 'movie', 'music', 'game', 'auto')]
        [string]$Mode
    )

    $code = switch ($Mode) {
        'stereo' { 'MSSTEREO' }
        'direct' { 'MSDIRECT' }
        { $_ -in @('pure', 'pure-direct') } { 'MSPURE DIRECT' }
        'movie' { 'MSMOVIE' }
        'music' { 'MSMUSIC' }
        'game' { 'MSGAME' }
        'auto' { 'MSAUTO' }
    }
    if ($PSCmdlet.ShouldProcess((Resolve-DenonReceiver).IpAddress, ('sound mode {0}' -f $Mode))) {
        Invoke-DenonTelnetCommand -Command $code | Out-Null
        [pscustomobject]@{ Mode = $Mode; Command = $code }
    }
}

function Set-DenonDynamicEq {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][ValidateSet('on', 'off')][string]$State)
    $code = 'PSDYNEQ {0}' -f $State.ToUpperInvariant()
    if ($PSCmdlet.ShouldProcess((Resolve-DenonReceiver).IpAddress, $code)) {
        Invoke-DenonTelnetCommand -Command $code | Out-Null
        [pscustomobject]@{ Name = 'Dynamic EQ'; State = $State; Command = $code }
    }
}

function Set-DenonCinemaEq {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][ValidateSet('on', 'off')][string]$State)
    $code = 'PSCINEMA EQ.{0}' -f $State.ToUpperInvariant()
    if ($PSCmdlet.ShouldProcess((Resolve-DenonReceiver).IpAddress, $code)) {
        Invoke-DenonTelnetCommand -Command $code | Out-Null
        [pscustomobject]@{ Name = 'Cinema EQ'; State = $State; Command = $code }
    }
}

function Set-DenonDynamicVolume {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][ValidateSet('off', 'light', 'medium', 'heavy')][string]$Level)
    $map = @{ off = 'OFF'; light = 'LIT'; medium = 'MED'; heavy = 'HEV' }
    $code = 'PSDYNVOL {0}' -f $map[$Level]
    if ($PSCmdlet.ShouldProcess((Resolve-DenonReceiver).IpAddress, $code)) {
        Invoke-DenonTelnetCommand -Command $code | Out-Null
        [pscustomobject]@{ Name = 'Dynamic Volume'; Level = $Level; Command = $code }
    }
}

function Set-DenonMultEq {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][ValidateSet('reference', 'audyssey', 'bypass-lr', 'flat', 'manual', 'off')][string]$Mode)
    $map = @{ reference = 'AUDYSSEY'; audyssey = 'AUDYSSEY'; 'bypass-lr' = 'BYP.LR'; flat = 'FLAT'; manual = 'MANUAL'; off = 'OFF' }
    $code = 'PSMULTEQ:{0}' -f $map[$Mode]
    if ($PSCmdlet.ShouldProcess((Resolve-DenonReceiver).IpAddress, $code)) {
        Invoke-DenonTelnetCommand -Command $code | Out-Null
        [pscustomobject]@{ Name = 'MultEQ'; Mode = $Mode; Command = $code }
    }
}

function Set-DenonTone {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('bass', 'treble')][string]$Control,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $prefix = if ($Control -eq 'bass') { 'PSBAS' } else { 'PSTRE' }
    if ($Value -match '^(?i:up|down)$') {
        $command = '{0} {1}' -f $prefix, $Value.ToUpperInvariant()
    }
    else {
        $db = 0.0
        if (-not [double]::TryParse($Value, [ref]$db) -or $db -lt -6 -or $db -gt 6) {
            throw ('{0} must be up, down, or a value from -6 to 6.' -f $Control)
        }
        $command = '{0} {1:00}' -f $prefix, [int]($db + 50)
    }
    if ($PSCmdlet.ShouldProcess((Resolve-DenonReceiver).IpAddress, $command)) {
        Invoke-DenonTelnetCommand -Command $command | Out-Null
        [pscustomobject]@{ Control = $Control; Value = $Value; Command = $command }
    }
}

function Invoke-DenonTransport {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][ValidateSet('play', 'pause', 'stop', 'next', 'prev', 'previous')][string]$Action)
    $map = @{ play = 'NS9A'; pause = 'NS9B'; stop = 'NS9C'; next = 'NS9D'; prev = 'NS9E'; previous = 'NS9E' }
    $command = $map[$Action]
    if ($PSCmdlet.ShouldProcess((Resolve-DenonReceiver).IpAddress, $command)) {
        Invoke-DenonTelnetCommand -Command $command | Out-Null
        [pscustomobject]@{ Action = $Action; Command = $command }
    }
}

function Invoke-DenonHeos {
    <#
    .SYNOPSIS
    Runs the HEOS helper command surface used by the Bash implementation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Argument
    )

    if ($null -eq $Argument -or $Argument.Count -eq 0) {
        Set-DenonSource -Name 'HEOS Music'
        return
    }

    $receiver = Resolve-DenonReceiver
    $helper = Get-DenonConfiguredValue -Name 'DENON_HEOS_HELPER'
    if ([string]::IsNullOrWhiteSpace($helper)) {
        $helper = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path 'denon_heos_helper.py'
    }
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
        throw ('HEOS helper not found: {0}' -f $helper)
    }
    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        $python = Get-Command python -ErrorAction SilentlyContinue
    }
    if ($null -eq $python) {
        throw 'python3 or python is required for HEOS queue, group, browse, and play-mode commands.'
    }

    $output = & $python.Source $helper $receiver.IpAddress @Argument 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw ($output -join [Environment]::NewLine)
    }
    $output
}

function Get-DenonDataFields {
    [CmdletBinding()]
    param([switch]$Available)

    $fields = @(
        'receiver.name', 'receiver.ip', 'receiver.brand_code', 'receiver.model_type',
        'main_zone.power', 'main_zone.source_index', 'main_zone.source_name',
        'main_zone.volume_raw', 'main_zone.volume_db', 'main_zone.muted',
        'zone2.power', 'zone2.source_index', 'zone2.source_name', 'zone2.volume_raw',
        'zone2.volume_db', 'zone2.muted', 'system.setup_lock', 'system.menu_lock',
        'system.advanced_mode', 'system.ci_mode', 'system.speaker_preset',
        'system.gui_type', 'system.webui_type', 'system.product_type',
        'network_heos.heos_model', 'network_heos.heos_version', 'network_heos.network',
        'now_playing.title', 'now_playing.artist', 'now_playing.album',
        'upnp.pending_upgrade_version', 'upnp.aios_firmware'
    )

    if (-not $Available.IsPresent) {
        return $fields | ForEach-Object { [pscustomobject]@{ Field = $_; Available = $null } }
    }

    $summary = Get-DenonReceiverSummary
    $json = $summary | ConvertTo-Json -Depth 8
    foreach ($field in $fields) {
        [pscustomobject]@{ Field = $field; Available = ($json -match [regex]::Escape(($field -split '\.')[-1])) }
    }
}

function Get-DenonDataSummary {
    [CmdletBinding()]
    param()
    Get-DenonReceiverSummary
}

function Get-DenonDataDump {
    [CmdletBinding()]
    param(
        [switch]$Raw,
        [switch]$Full
    )

    $max = Get-DenonConfiguredValue -Name 'DENON_DATA_DISCOVERY_MAX_TYPE'
    $maxType = 30
    if (-not [string]::IsNullOrWhiteSpace($max)) {
        [void][int]::TryParse($max, [ref]$maxType)
    }
    $configs = [ordered]@{}
    for ($type = 0; $type -le $maxType; $type++) {
        try {
            $body = Get-DenonRawConfig -Type $type
            if (-not [string]::IsNullOrWhiteSpace($body)) {
                $configs[[string]$type] = if ($Raw.IsPresent -and -not $Full.IsPresent -and $body.Length -gt 20000) { $body.Substring(0, 20000) } else { $body }
            }
        }
        catch {
            Write-Verbose ('get_config type {0} unavailable: {1}' -f $type, $_.Exception.Message)
        }
    }
    [pscustomobject]@{ GetConfig = $configs; Summary = if (-not $Raw.IsPresent) { Get-DenonReceiverSummary } else { $null } }
}

function Get-DenonDataCapabilities {
    [CmdletBinding()]
    param(
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Source)) {
        $Source = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path 'references/deviceinfo_capabilities.xml'
    }
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw ('Capability source not found: {0}' -f $Source)
    }
    $xml = [xml](Get-Content -LiteralPath $Source -Raw)
    $nodes = $xml.SelectNodes('//*[local-name()="FuncName"]')
    foreach ($node in $nodes) {
        $verb = ([string]$node.InnerText).Trim()
        if ([string]::IsNullOrWhiteSpace($verb)) { continue }
        $lower = $verb.ToLowerInvariant()
        $safety = if ($lower -match '^(set|put|update|upgrade|factory|reset|reboot|delete|pair|register|login|account|write)' -or
            $lower -match '(firmware|update|upgrade|factory|reboot|delete|pair|register|login|account|write|factoryreset|resetdefault)') {
            'skipped'
        }
        else {
            'known-safe'
        }
        [pscustomobject]@{ Source = $Source; Verb = $verb; Safety = $safety }
    }
}

function Save-DenonSnapshot {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path (Get-DenonPlatformPath -Kind Data) ('snapshots/{0:yyyyMMdd-HHmmss}' -f (Get-Date))
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    foreach ($type in @(3, 4, 7, 12)) {
        Set-Content -LiteralPath (Join-Path $Path ('get_config_{0}.xml' -f $type)) -Value (Get-DenonRawConfig -Type $type) -Encoding utf8
    }
    [pscustomobject]@{ Path = (Resolve-Path -LiteralPath $Path).Path; Saved = $true }
}

function Compare-DenonSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ReferencePath,
        [Parameter(Mandatory = $true)][string]$DifferencePath
    )

    $files = @(Get-ChildItem -LiteralPath $ReferencePath -File -ErrorAction Stop | Select-Object -ExpandProperty Name)
    foreach ($name in $files) {
        $a = Join-Path $ReferencePath $name
        $b = Join-Path $DifferencePath $name
        if (-not (Test-Path -LiteralPath $b -PathType Leaf)) {
            [pscustomobject]@{ File = $name; Status = 'missing-in-difference' }
            continue
        }
        $hashA = (Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash
        $hashB = (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash
        [pscustomobject]@{ File = $name; Status = if ($hashA -eq $hashB) { 'same' } else { 'different' } }
    }
}

function Invoke-DenonDoctor {
    [CmdletBinding()]
    param()

    $receiver = $null
    $test = $null
    try {
        $receiver = Resolve-DenonReceiver
        $test = Test-DenonReceiver
    }
    catch {
        $test = [pscustomobject]@{ Responded = $false; IsDenon = $false; Error = $_.Exception.Message }
    }

    [pscustomobject]@{
        PowerShell = $PSVersionTable.PSVersion.ToString()
        ModuleVersion = $script:DenonControllerVersion
        ConfigPath = Get-DenonPlatformPath -Kind Config
        CachePath = Get-DenonPlatformPath -Kind Cache
        Receiver = $receiver
        ReceiverTest = $test
        Python = [bool](Get-Command python3 -ErrorAction SilentlyContinue)
    }
}

function Invoke-DenonDataDiscover {
    [CmdletBinding()]
    param()

    $receiver = Resolve-DenonReceiver
    $records = New-Object System.Collections.Generic.List[object]
    $paths = New-Object System.Collections.Generic.List[string]
    $paths.Add('/general/general.html')

    for ($i = 0; $i -lt $paths.Count -and $i -lt 50; $i++) {
        $path = $paths[$i]
        if ($path -notmatch '^/[A-Za-z0-9_./?=&%-]+$') { continue }
        if ($path -match '(?i)set_config|reset|delete|update|upgrade|factory|write|save|apply|logout|password|account') { continue }
        try {
            $body = Invoke-DenonPlainHttpGet -Path $path -Port 80 -Receiver $receiver
        }
        catch {
            Write-Verbose ('discover path failed {0}: {1}' -f $path, $_.Exception.Message)
            continue
        }
        if ([string]::IsNullOrWhiteSpace($body)) { continue }

        $summary = ([regex]::Replace(($body -replace '<[^>]*>', ' '), '\s+', ' ')).Trim()
        if ($summary.Length -gt 160) { $summary = $summary.Substring(0, 160) }
        $records.Add([pscustomobject]@{ Path = $path; Status = 'ok'; ContentType = 'unknown'; Summary = $summary })

        foreach ($match in [regex]::Matches($body, '["''](?<path>/[A-Za-z0-9_./?=&%-]+)["'']')) {
            $candidate = $match.Groups['path'].Value
            if ($candidate -match '(?i)set_config|reset|delete|update|upgrade|factory|write|save|apply|logout|password|account') { continue }
            if (-not $paths.Contains($candidate)) { $paths.Add($candidate) }
        }
    }

    $records
}

function Invoke-DenonListeningPreset {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('movie', 'game', 'night', 'music')]
        [string]$Name
    )

    $sourceKey = 'DENON_{0}_SOURCE' -f $Name.ToUpperInvariant()
    $volumeKey = 'DENON_{0}_VOLUME_DB' -f $Name.ToUpperInvariant()
    $modeKey = 'DENON_{0}_MODE' -f $Name.ToUpperInvariant()
    $defaultSource = switch ($Name) {
        'movie' { 'tv audio' }
        'game' { 'xbox' }
        'night' { 'tv audio' }
        'music' { 'heos music' }
    }
    $defaultVolume = switch ($Name) {
        'movie' { '-32' }
        'game' { '-30' }
        'night' { '-45' }
        'music' { '-35' }
    }
    $defaultMode = switch ($Name) {
        'movie' { 'movie' }
        'game' { 'game' }
        'night' { $null }
        'music' { 'music' }
    }
    $source = Get-DenonConfiguredValue -Name $sourceKey
    if ([string]::IsNullOrWhiteSpace($source)) { $source = $defaultSource }
    $volume = Get-DenonConfiguredValue -Name $volumeKey
    if ([string]::IsNullOrWhiteSpace($volume)) { $volume = $defaultVolume }
    $mode = Get-DenonConfiguredValue -Name $modeKey
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = $defaultMode }

    $receiver = Resolve-DenonReceiver
    if ($PSCmdlet.ShouldProcess($receiver.IpAddress, ('apply {0} preset' -f $Name))) {
        Set-DenonPower -On | Out-Null
        Set-DenonSource -Name $source | Out-Null
        Set-DenonVolume -Db ([double]$volume) | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($mode)) {
            Set-DenonSoundMode -Mode $mode | Out-Null
        }
        Get-DenonStatus
    }
}

function Switch-DenonPowerOrMute {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidateSet('mute', 'power')]
        [string]$Target = 'mute'
    )

    if ($Target -eq 'power') {
        $status = Get-DenonStatus
        if ($status.Power -eq 'ON') { Set-DenonPower -Off } else { Set-DenonPower -On }
        return
    }
    $status = Get-DenonStatus
    if ($status.Muted -eq $true) { Set-DenonMute -Off } else { Set-DenonMute -On }
}

function Watch-DenonEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Condition,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [double]$IntervalSeconds = 5,

        [switch]$Once,

        [int]$TimeoutSeconds = 0
    )

    if ($Condition -notmatch '^([A-Za-z_]+)(<=|>=|!=|==|=|<|>)(.+)$') {
        throw "Cannot parse condition '$Condition'. Examples: source=tv power=on mute=off vol<-30"
    }
    $key = $Matches[1].ToLowerInvariant()
    $operator = $Matches[2]
    $expected = $Matches[3].Trim().ToLowerInvariant()
    $started = Get-Date

    while ($true) {
        if ($TimeoutSeconds -gt 0 -and ((Get-Date) - $started).TotalSeconds -ge $TimeoutSeconds) {
            throw ('Timeout after {0}s; condition never met: {1}' -f $TimeoutSeconds, $Condition)
        }
        $status = Get-DenonStatus
        $actual = switch ($key) {
            'source' { [string]$status.SourceName }
            'power' { [string]$status.Power }
            'mute' { if ($status.Muted -eq $true) { 'on' } elseif ($status.Muted -eq $false) { 'off' } else { 'unknown' } }
            'vol' { [string]$status.VolumeDb }
            'volume' { [string]$status.VolumeDb }
            default { throw ('Unsupported condition key: {0}' -f $key) }
        }
        $actualLower = $actual.ToLowerInvariant()
        $met = switch ($operator) {
            '=' { $actualLower -eq $expected }
            '==' { $actualLower -eq $expected }
            '!=' { $actualLower -ne $expected }
            '<' { [double]$actual -lt [double]$expected }
            '>' { [double]$actual -gt [double]$expected }
            '<=' { [double]$actual -le [double]$expected }
            '>=' { [double]$actual -ge [double]$expected }
        }
        if ($met) {
            & $Action
            if ($Once.IsPresent) { return }
        }
        Start-Sleep -Milliseconds ([int]($IntervalSeconds * 1000))
    }
}

function Get-DenonConfig {
    [CmdletBinding()]
    param([string]$Key)

    $path = Get-DenonPlatformPath -Kind Config
    $fileValues = Read-DenonKeyValueFile -Path $path
    if (-not [string]::IsNullOrWhiteSpace($Key)) {
        if ($script:DenonKnownConfigKeys -notcontains $Key) { throw ('Unknown config key: {0}' -f $Key) }
        return [pscustomobject]@{ Key = $Key; Value = (Get-DenonConfiguredValue -Name $Key); Path = $path }
    }
    foreach ($known in $script:DenonKnownConfigKeys) {
        $env = [Environment]::GetEnvironmentVariable($known)
        $file = if ($fileValues.Contains($known)) { [string]$fileValues[$known] } else { $null }
        [pscustomobject]@{
            Key = $known
            EffectiveValue = if (-not [string]::IsNullOrWhiteSpace($env)) { $env } elseif ($null -ne $file) { $file } else { $null }
            Source = if (-not [string]::IsNullOrWhiteSpace($env)) { 'env' } elseif ($null -ne $file) { 'file' } else { $null }
            Path = $path
        }
    }
}

function Set-DenonConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateScript({ $script:DenonKnownConfigKeys -contains $_ })][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $path = Get-DenonPlatformPath -Kind Config
    Set-DenonKeyValueFileValue -Path $path -Key $Key -Value $Value
    [pscustomobject]@{ Key = $Key; Value = $Value; Path = $path }
}

function Remove-DenonConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Key)
    $path = Get-DenonPlatformPath -Kind Config
    [pscustomobject]@{ Key = $Key; Removed = (Remove-DenonKeyValueFileValue -Path $path -Key $Key); Path = $path }
}

function Get-DenonProfilePath {
    [CmdletBinding()]
    param([string]$Name)

    $dir = Join-Path (Split-Path -Parent (Get-DenonPlatformPath -Kind Config)) 'profiles'
    if ([string]::IsNullOrWhiteSpace($Name)) { return $dir }
    Test-DenonStoredName -Kind profile -Name $Name
    Join-Path $dir $Name
}

function Get-DenonProfile {
    [CmdletBinding()]
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $dir = Get-DenonProfilePath
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
        Get-ChildItem -LiteralPath $dir -File | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Path = $_.FullName; Active = ($_.Name -eq [Environment]::GetEnvironmentVariable('DENON_PROFILE')) }
        }
        return
    }
    $path = Get-DenonProfilePath -Name $Name
    $values = Read-DenonKeyValueFile -Path $path
    [pscustomobject]@{ Name = $Name; Path = $path; Values = $values }
}

function Set-DenonProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateScript({ $script:DenonKnownConfigKeys -contains $_ })][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $path = Get-DenonProfilePath -Name $Name
    Set-DenonKeyValueFileValue -Path $path -Key $Key -Value $Value
    [pscustomobject]@{ Name = $Name; Key = $Key; Value = $Value; Path = $path }
}

function Remove-DenonProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Key
    )
    $path = Get-DenonProfilePath -Name $Name
    if ([string]::IsNullOrWhiteSpace($Key)) {
        Remove-Item -LiteralPath $path -Force
        return [pscustomobject]@{ Name = $Name; Removed = $true; Path = $path }
    }
    [pscustomobject]@{ Name = $Name; Key = $Key; Removed = (Remove-DenonKeyValueFileValue -Path $path -Key $Key); Path = $path }
}

function Rename-DenonSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet(1, 2)][int]$Zone = 1
    )
    $sourceXml = Get-DenonConfigXml -Type 7
    $resolved = if ($Source -match '^[0-9]+$') {
        Resolve-DenonSourceIndex -SourceXml $sourceXml -Zone $Zone -Index ([int]$Source)
    }
    else {
        Resolve-DenonSourceIndex -SourceXml $sourceXml -Zone $Zone -Name $Source
    }
    $path = Get-DenonSourceAliasPath
    $directory = Split-Path -Parent $path
    if (-not [string]::IsNullOrWhiteSpace($directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $lines = @()
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $path | Where-Object { $_ -notmatch ('^{0}\t{1}\t' -f $Zone, $resolved.Index) })
    }
    $lines += ('{0}{1}{2}{1}{3}' -f $Zone, "`t", $resolved.Index, $Name)
    Set-Content -LiteralPath $path -Value $lines -Encoding utf8
    [pscustomobject]@{ Zone = $Zone; SourceIndex = $resolved.Index; DisplayName = $Name; Path = $path }
}

function Clear-DenonSourceName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [ValidateSet(1, 2)][int]$Zone = 1
    )
    $sourceXml = Get-DenonConfigXml -Type 7
    $resolved = if ($Source -match '^[0-9]+$') {
        Resolve-DenonSourceIndex -SourceXml $sourceXml -Zone $Zone -Index ([int]$Source)
    }
    else {
        Resolve-DenonSourceIndex -SourceXml $sourceXml -Zone $Zone -Name $Source
    }
    $path = Get-DenonSourceAliasPath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $path | Where-Object { $_ -notmatch ('^{0}\t{1}\t' -f $Zone, $resolved.Index) })
        Set-Content -LiteralPath $path -Value $lines -Encoding utf8
    }
    [pscustomobject]@{ Zone = $Zone; SourceIndex = $resolved.Index; Cleared = $true; Path = $path }
}

function Get-DenonSourceNames {
    [CmdletBinding()]
    param()
    $aliases = Read-DenonSourceAliases
    foreach ($key in $aliases.Keys) {
        $zone, $index = $key -split ':', 2
        [pscustomobject]@{ Zone = [int]$zone; SourceIndex = [int]$index; DisplayName = $aliases[$key]; Path = (Get-DenonSourceAliasPath) }
    }
}

function Invoke-DenonPreset {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('save', 'load', 'list', 'show', 'delete')][string]$Action,
        [string]$Name
    )

    $dir = Join-Path (Get-DenonPlatformPath -Kind Data) 'presets'
    if ($Action -eq 'list') {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
        Get-ChildItem -LiteralPath $dir -File | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Path = $_.FullName }
        }
        return
    }
    if ([string]::IsNullOrWhiteSpace($Name)) { throw ('Name is required for preset {0}.' -f $Action) }
    Test-DenonStoredName -Kind preset -Name $Name
    $path = Join-Path $dir $Name
    switch ($Action) {
        'save' {
            $info = Get-DenonInfo
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $lines = @(
                '# denon-preset v1',
                ('# saved: {0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date)),
                ('main_power={0}' -f $(if ($info.MainZone.Power -eq 'ON') { 1 } else { 3 })),
                ('main_source={0}' -f $info.MainZone.SourceIndex),
                ('main_volume={0}' -f $info.MainZone.VolumeRaw),
                ('main_mute={0}' -f $(if ($info.MainZone.Muted) { 1 } else { 2 })),
                ('zone2_power={0}' -f $(if ($info.Zone2.Power -eq 'ON') { 1 } else { 3 })),
                ('zone2_source={0}' -f $info.Zone2.SourceIndex),
                ('zone2_volume={0}' -f $info.Zone2.VolumeRaw),
                ('zone2_mute={0}' -f $(if ($info.Zone2.Muted) { 1 } else { 2 }))
            )
            Set-Content -LiteralPath $path -Value $lines -Encoding utf8
            [pscustomobject]@{ Name = $Name; Path = $path; Saved = $true }
        }
        'show' {
            Get-Content -LiteralPath $path
        }
        'delete' {
            Remove-Item -LiteralPath $path -Force
            [pscustomobject]@{ Name = $Name; Path = $path; Deleted = $true }
        }
        'load' {
            $values = Read-DenonKeyValueFile -Path $path
            if ($PSCmdlet.ShouldProcess((Resolve-DenonReceiver).IpAddress, ('load preset {0}' -f $Name))) {
                if ($values.main_power) { Invoke-DenonSetConfig -Type 4 -Data ('<MainZone><Power>{0}</Power></MainZone>' -f $values.main_power) }
                if ($values.main_source) { Invoke-DenonSetConfig -Type 7 -Data ('<Source zone="1" index="{0}"></Source>' -f $values.main_source) }
                if ($values.main_volume) { Invoke-DenonSetConfig -Type 12 -Data ('<MainZone><Volume>{0}</Volume></MainZone>' -f $values.main_volume) }
                if ($values.main_mute) { Invoke-DenonSetConfig -Type 12 -Data ('<MainZone><Mute>{0}</Mute></MainZone>' -f $values.main_mute) }
                if ($values.zone2_power) { Invoke-DenonSetConfig -Type 4 -Data ('<Zone2><Power>{0}</Power></Zone2>' -f $values.zone2_power) }
                if ($values.zone2_source) { Invoke-DenonSetConfig -Type 7 -Data ('<Source zone="2" index="{0}"></Source>' -f $values.zone2_source) }
                if ($values.zone2_volume) { Invoke-DenonSetConfig -Type 12 -Data ('<Zone2><Volume>{0}</Volume></Zone2>' -f $values.zone2_volume) }
                if ($values.zone2_mute) { Invoke-DenonSetConfig -Type 12 -Data ('<Zone2><Mute>{0}</Mute></Zone2>' -f $values.zone2_mute) }
                [pscustomobject]@{ Name = $Name; Path = $path; Loaded = $true }
            }
        }
    }
}

function Get-DenonCompletionCommandSurface {
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        Commands = $script:DenonCommandSurface
        HeosCommands = $script:DenonHeosCommandSurface
        Zone2Commands = @('status', 'sources', 'source', 'rename-source', 'clear-source-name', 'on', 'off', 'mute', 'unmute', 'vol', 'volume', 'up', 'down', 'sleep')
        DataCommands = @('fields', 'dump', 'discover', 'capabilities', 'summary')
        CompletionCommands = @('bash', 'zsh', 'fish', 'install')
    }
}

function Register-DenonArgumentCompleter {
    [CmdletBinding()]
    param()

    Register-ArgumentCompleter -CommandName Invoke-DenonCommand -ParameterName Argument -ScriptBlock {
        param($commandName, $parameterName, $wordToComplete)
        $script:DenonCommandSurface |
            Where-Object { $_ -like "$wordToComplete*" } |
            ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
    }
}

function Invoke-DenonCommand {
    <#
    .SYNOPSIS
    PowerShell command-surface shim for users migrating from denon.sh.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Argument
    )

    if ($null -eq $Argument -or $Argument.Count -eq 0 -or $Argument[0] -in @('help', '--help', '-h')) {
        Get-DenonCompletionCommandSurface
        return
    }
    $cmd = $Argument[0].ToLowerInvariant()
    $rest = @($Argument | Select-Object -Skip 1)
    $defaultStep = Get-DenonConfiguredValue -Name 'DENON_VOLUME_STEP_DB'
    if ([string]::IsNullOrWhiteSpace($defaultStep)) { $defaultStep = '1' }
    switch ($cmd) {
        'version' { $script:DenonControllerVersion }
        'status' { Get-DenonStatus }
        'info' { Get-DenonInfo }
        'dashboard' { Show-DenonDashboard }
        'sources' { Get-DenonSources -Zone $(if ($rest.Count -and $rest[0] -eq '2') { 2 } else { 1 }) }
        'source' { Set-DenonSource -Name ($rest -join ' ') }
        'rename-source' { Rename-DenonSource -Source $rest[0] -Name (($rest | Select-Object -Skip 1) -join ' ') }
        'source-names' { Get-DenonSourceNames }
        'clear-source-name' { Clear-DenonSourceName -Source $rest[0] }
        'on' { Set-DenonPower -On }
        'off' { Set-DenonPower -Off }
        'mute' { Set-DenonMute -On }
        'unmute' { Set-DenonMute -Off }
        'toggle' { Switch-DenonPowerOrMute -Target $(if ($rest.Count) { $rest[0] } else { 'mute' }) }
        'vol' {
            if ($rest.Count -eq 0) { (Get-DenonStatus).VolumeDb }
            elseif ($rest[0].StartsWith('+')) { Step-DenonVolume -Db ([double]$rest[0].Substring(1)) }
            else { Set-DenonVolume -Db ([double]$rest[0]) }
        }
        'up' { Step-DenonVolume -Db $(if ($rest.Count) { [double]$rest[0] } else { [double]$defaultStep }) }
        'down' { Step-DenonVolume -Db -($(if ($rest.Count) { [double]$rest[0] } else { [double]$defaultStep })) }
        'mode' { Set-DenonSoundMode -Mode $rest[0] }
        'dyn-eq' { Set-DenonDynamicEq -State $rest[0] }
        'dyn-vol' { Set-DenonDynamicVolume -Level $rest[0] }
        'cinema-eq' { Set-DenonCinemaEq -State $rest[0] }
        'multeq' { Set-DenonMultEq -Mode $rest[0] }
        'bass' { Set-DenonTone -Control bass -Value $rest[0] }
        'treble' { Set-DenonTone -Control treble -Value $rest[0] }
        { $_ -in @('play', 'pause', 'stop', 'next', 'prev', 'previous') } { Invoke-DenonTransport -Action $cmd }
        { $_ -in @('track', 'now') } { Get-DenonNowPlaying }
        'heos' { Invoke-DenonHeos @rest }
        'sleep' { if ($rest.Count) { Set-DenonSleep -Value $rest[0] } else { Get-DenonSleep } }
        { $_ -in @('qs', 'quick', 'quick-select') } {
            if ($rest.Count -gt 1 -and $rest[0] -in @('save', 'store', 'memory')) {
                Invoke-DenonQuickSelect -Number ([int]$rest[1]) -Save
            }
            else {
                Invoke-DenonQuickSelect -Number ([int]$rest[0])
            }
        }
        'rawstatus' { Get-DenonRawStatus }
        'raw' { if ($rest[0] -eq 'get') { Get-DenonRawConfig -Type ([int]$rest[1]) } elseif ($rest[0] -eq 'set') { Set-DenonRawConfig -Type ([int]$rest[1]) -Xml (($rest | Select-Object -Skip 2) -join ' ') } else { throw 'Usage: raw get <type> | raw set <type> <xml>' } }
        'snapshot' { Save-DenonSnapshot -Path $rest[0] }
        'diff' { Compare-DenonSnapshot -ReferencePath $rest[0] -DifferencePath $rest[1] }
        'doctor' { Invoke-DenonDoctor }
        'watch-event' {
            $condition = $rest[0]
            $commandText = $rest[1]
            Watch-DenonEvent -Condition $condition -Action ([scriptblock]::Create($commandText)) -Once
        }
        'discover' { Find-DenonReceiver -RefreshCache }
        'setip' { Set-DenonReceiverIp -IpAddress $rest[0] }
        'config' {
            if ($rest.Count -eq 0) { Get-DenonConfig }
            elseif ($rest[0] -eq 'path') { Get-DenonPlatformPath -Kind Config }
            elseif ($rest[0] -eq 'set') { Set-DenonConfig -Key $rest[1] -Value (($rest | Select-Object -Skip 2) -join ' ') }
            elseif ($rest[0] -eq 'unset') { Remove-DenonConfig -Key $rest[1] }
            else { throw 'Usage: config [set KEY VALUE | unset KEY | path]' }
        }
        'profile' {
            if ($rest.Count -eq 0 -or $rest[0] -eq 'list') { Get-DenonProfile }
            elseif ($rest[0] -eq 'path') { Get-DenonProfilePath -Name $rest[1] }
            elseif ($rest[0] -eq 'show') { Get-DenonProfile -Name $rest[1] }
            elseif ($rest[0] -eq 'set') { Set-DenonProfile -Name $rest[1] -Key $rest[2] -Value (($rest | Select-Object -Skip 3) -join ' ') }
            elseif ($rest[0] -eq 'unset') { Remove-DenonProfile -Name $rest[1] -Key $rest[2] }
            else { throw 'Usage: profile <list|show|path|set|unset>' }
        }
        'preset' { Invoke-DenonPreset -Action $rest[0] -Name $rest[1] }
        'data' {
            if ($rest[0] -eq 'fields') { Get-DenonDataFields -Available:($rest -contains '--available') }
            elseif ($rest[0] -eq 'summary') { Get-DenonDataSummary }
            elseif ($rest[0] -eq 'dump') { Get-DenonDataDump -Raw:($rest -contains '--raw') -Full:($rest -contains '--full') }
            elseif ($rest[0] -eq 'capabilities') { Get-DenonDataCapabilities }
            elseif ($rest[0] -eq 'discover') { Invoke-DenonDataDiscover }
            else { throw 'Unsupported data subcommand.' }
        }
        'completion' { Get-DenonCompletionCommandSurface }
        'zone2' {
            $sub = $rest[0]
            if ($sub -eq 'status') { Get-DenonZone2Status }
            elseif ($sub -eq 'sources') { Get-DenonSources -Zone 2 }
            elseif ($sub -eq 'source') { Set-DenonZone2Source -Name ($rest[1..($rest.Count - 1)] -join ' ') }
            elseif ($sub -eq 'rename-source') { Rename-DenonSource -Zone 2 -Source $rest[1] -Name ($rest[2..($rest.Count - 1)] -join ' ') }
            elseif ($sub -eq 'clear-source-name') { Clear-DenonSourceName -Zone 2 -Source $rest[1] }
            elseif ($sub -eq 'on') { Set-DenonZone2Power -On }
            elseif ($sub -eq 'off') { Set-DenonZone2Power -Off }
            elseif ($sub -eq 'mute') { Set-DenonZone2Mute -On }
            elseif ($sub -eq 'unmute') { Set-DenonZone2Mute -Off }
            elseif ($sub -in @('vol', 'volume')) { Set-DenonZone2Volume -Raw ([int]$rest[1]) }
            elseif ($sub -eq 'up') { Step-DenonZone2Volume -Db $(if ($rest.Count -gt 1) { [double]$rest[1] } else { 1 }) }
            elseif ($sub -eq 'down') { Step-DenonZone2Volume -Db -($(if ($rest.Count -gt 1) { [double]$rest[1] } else { 1 })) }
            elseif ($sub -eq 'sleep') { if ($rest.Count -gt 1) { Set-DenonSleep -Zone 2 -Value $rest[1] } else { Get-DenonSleep -Zone 2 } }
            else { throw 'Unsupported zone2 subcommand.' }
        }
        default {
            $shortcuts = @{ xbox = 'xbox'; xfinity = 'xfinity x1'; bluray = 'blu-ray'; tv = 'tv audio'; phono = 'phono' }
            if ($shortcuts.ContainsKey($cmd)) { Set-DenonSource -Name $shortcuts[$cmd] }
            elseif ($cmd -in @('movie', 'game', 'night', 'music')) { Invoke-DenonListeningPreset -Name $cmd }
            else { throw ('Unknown Denon command: {0}' -f $cmd) }
        }
    }
}

function Test-DenonAnsiSupport {
    [CmdletBinding()]
    param()

    try {
        if ($null -ne $Host.UI -and
            $null -ne $Host.UI.RawUI -and
            ($Host.UI.RawUI | Get-Member -Name SupportsVirtualTerminal -ErrorAction SilentlyContinue)) {
            return [bool]$Host.UI.RawUI.SupportsVirtualTerminal
        }
    }
    catch {
        return $false
    }

    return $false
}

function Show-DenonDashboard {
    <#
    .SYNOPSIS
    Read-only: Shows a simple native PowerShell dashboard.
    #>
    [CmdletBinding()]
    param()

    $info = Get-DenonInfo
    $title = 'Denon AVR Controller'
    if (Test-DenonAnsiSupport) {
        $escape = [char]27
        Write-Host ('{0}[1m{1}{0}[0m' -f $escape, $title)
    }
    else {
        Write-Host $title
    }

    Write-Host ('Receiver: {0}' -f $(if ([string]::IsNullOrWhiteSpace($info.Receiver)) { 'Unknown' } else { $info.Receiver }))
    Write-Host ('IP:       {0}:{1}' -f $info.IpAddress, $info.Port)
    Write-Host ''
    Write-Host 'Main Zone'
    Write-Host ('  Power:  {0}' -f $info.MainZone.Power)
    Write-Host ('  Source: {0} ({1})' -f $info.MainZone.SourceName, $info.MainZone.SourceIndex)
    Write-Host ('  Volume: {0} dB' -f $(if ($null -eq $info.MainZone.VolumeDb) { 'Unknown' } else { $info.MainZone.VolumeDb }))
    Write-Host ('  Muted:  {0}' -f (ConvertTo-DenonMuteLabel -Muted $info.MainZone.Muted))
    Write-Host ''
    Write-Host 'Zone 2'
    Write-Host ('  Power:  {0}' -f $info.Zone2.Power)
    Write-Host ('  Source: {0} ({1})' -f $info.Zone2.SourceName, $info.Zone2.SourceIndex)
    Write-Host ('  Volume: {0} dB (raw {1})' -f $(if ($null -eq $info.Zone2.VolumeDb) { 'Unknown' } else { $info.Zone2.VolumeDb }), $(if ($null -eq $info.Zone2.VolumeRaw) { 'Unknown' } else { $info.Zone2.VolumeRaw }))
    Write-Host ('  Muted:  {0}' -f (ConvertTo-DenonMuteLabel -Muted $info.Zone2.Muted))

    $nowPlaying = Get-DenonNowPlaying
    if ($null -ne $nowPlaying -and (
            -not [string]::IsNullOrWhiteSpace($nowPlaying.Title) -or
            -not [string]::IsNullOrWhiteSpace($nowPlaying.State) -or
            -not [string]::IsNullOrWhiteSpace($nowPlaying.Service))) {
        Write-Host ''
        Write-Host 'Now Playing'
        Write-Host ('  Title:   {0}' -f $(if ([string]::IsNullOrWhiteSpace($nowPlaying.Title)) { 'Unknown' } else { $nowPlaying.Title }))
        Write-Host ('  Artist:  {0}' -f $(if ([string]::IsNullOrWhiteSpace($nowPlaying.Artist)) { 'Unknown' } else { $nowPlaying.Artist }))
        Write-Host ('  Album:   {0}' -f $(if ([string]::IsNullOrWhiteSpace($nowPlaying.Album)) { 'Unknown' } else { $nowPlaying.Album }))
        Write-Host ('  Service: {0}' -f $(if ([string]::IsNullOrWhiteSpace($nowPlaying.Service)) { 'Unknown' } else { $nowPlaying.Service }))
        Write-Host ('  State:   {0}' -f $(if ([string]::IsNullOrWhiteSpace($nowPlaying.State)) { 'Unknown' } else { $nowPlaying.State }))
    }
}

Export-ModuleMember -Function @(
    'Invoke-DenonCommand',
    'Set-DenonReceiver',
    'Set-DenonReceiverIp',
    'Find-DenonReceiver',
    'Test-DenonReceiver',
    'Invoke-DenonDoctor',
    'Get-DenonInfo',
    'Get-DenonStatus',
    'Get-DenonReceiverSummary',
    'Get-DenonNowPlaying',
    'Get-DenonSources',
    'Get-DenonZone2Status',
    'Get-DenonSleep',
    'Set-DenonSleep',
    'Show-DenonDashboard',
    'Get-DenonRawConfig',
    'Set-DenonRawConfig',
    'Get-DenonRawStatus',
    'Get-DenonDataFields',
    'Get-DenonDataSummary',
    'Get-DenonDataDump',
    'Get-DenonDataCapabilities',
    'Invoke-DenonDataDiscover',
    'Save-DenonSnapshot',
    'Compare-DenonSnapshot',
    'Get-DenonConfig',
    'Set-DenonConfig',
    'Remove-DenonConfig',
    'Get-DenonProfile',
    'Set-DenonProfile',
    'Remove-DenonProfile',
    'Get-DenonProfilePath',
    'Rename-DenonSource',
    'Clear-DenonSourceName',
    'Get-DenonSourceNames',
    'Set-DenonPower',
    'Set-DenonMute',
    'Set-DenonVolume',
    'Step-DenonVolume',
    'Set-DenonSource',
    'Set-DenonZone2Source',
    'Set-DenonZone2Power',
    'Set-DenonZone2Mute',
    'Set-DenonZone2Volume',
    'Step-DenonZone2Volume',
    'Invoke-DenonQuickSelect',
    'Invoke-DenonListeningPreset',
    'Switch-DenonPowerOrMute',
    'Watch-DenonEvent',
    'Set-DenonSoundMode',
    'Set-DenonDynamicEq',
    'Set-DenonDynamicVolume',
    'Set-DenonCinemaEq',
    'Set-DenonMultEq',
    'Set-DenonTone',
    'Invoke-DenonTransport',
    'Invoke-DenonHeos',
    'Invoke-DenonPreset',
    'Get-DenonCompletionCommandSurface',
    'Register-DenonArgumentCompleter',
    'Invoke-DenonTelnetCommand'
)
