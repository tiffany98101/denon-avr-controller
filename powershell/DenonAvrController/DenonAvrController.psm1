$script:DenonControllerVersion = '1.2.0-beta.1'

$script:DenonReceiverConfig = [ordered]@{
    IpAddress = $null
    Port = 10443
    Name = $null
    TimeoutSeconds = 4
    TelnetPort = 23
    SkipCertificateCheck = $false
    MaxVolumeDb = -10.0
}

function Resolve-DenonReceiver {
    [CmdletBinding()]
    param()

    $ipAddress = $script:DenonReceiverConfig.IpAddress
    if ([string]::IsNullOrWhiteSpace($ipAddress)) {
        $ipAddress = [Environment]::GetEnvironmentVariable('DENON_IP')
    }
    if ([string]::IsNullOrWhiteSpace($ipAddress)) {
        $ipAddress = [Environment]::GetEnvironmentVariable('DENON_DEFAULT_IP')
    }
    if ([string]::IsNullOrWhiteSpace($ipAddress)) {
        throw 'No Denon receiver IP is configured. Run Set-DenonReceiver -IpAddress <address>, or set DENON_IP or DENON_DEFAULT_IP.'
    }

    [pscustomobject]@{
        IpAddress = $ipAddress
        Port = [int]$script:DenonReceiverConfig.Port
        Name = $script:DenonReceiverConfig.Name
        TimeoutSeconds = [int]$script:DenonReceiverConfig.TimeoutSeconds
        TelnetPort = [int]$script:DenonReceiverConfig.TelnetPort
        SkipCertificateCheck = [bool]$script:DenonReceiverConfig.SkipCertificateCheck
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
    $script:DenonReceiverConfig.SkipCertificateCheck = $SkipCertificateCheck.IsPresent
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

function Invoke-DenonHttpGet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [int]$TimeoutSeconds = 4,

        [bool]$SkipCertificateCheck = $false
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

    $changedCertificateCallback = $false
    $oldCertificateCallback = $null

    if ($SkipCertificateCheck -and $command.Parameters.ContainsKey('SkipCertificateCheck')) {
        $parameters['SkipCertificateCheck'] = $true
    }
    elseif ($SkipCertificateCheck) {
        $oldCertificateCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
            param($sender, $certificate, $chain, $sslPolicyErrors)
            $true
        }
        $changedCertificateCallback = $true
    }

    try {
        $response = Invoke-WebRequest @parameters
        return [string]$response.Content
    }
    catch {
        $hint = ''
        if (-not $SkipCertificateCheck -and $_.Exception.Message -match 'certificate|SSL|TLS|trust') {
            $hint = ' If this receiver uses a self-signed certificate, run Set-DenonReceiver again with -SkipCertificateCheck.'
        }

        throw ('Denon HTTP request failed for {0}: {1}{2}' -f $Uri, $_.Exception.Message, $hint)
    }
    finally {
        if ($changedCertificateCallback) {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCertificateCallback
        }
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
    Invoke-DenonHttpGet -Uri $uri -TimeoutSeconds $Receiver.TimeoutSeconds -SkipCertificateCheck $Receiver.SkipCertificateCheck
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
    [void](Invoke-DenonHttpGet -Uri $uri -TimeoutSeconds $Receiver.TimeoutSeconds -SkipCertificateCheck $Receiver.SkipCertificateCheck)
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

    foreach ($sourceNode in $sourceNodes) {
        $index = ConvertTo-DenonNullableInt -Value $sourceNode.GetAttribute('index')
        $receiverName = Get-DenonChildText -Node $sourceNode -ChildName 'Name'
        if ([string]::IsNullOrWhiteSpace($receiverName)) {
            $receiverName = 'Unknown'
        }

        [pscustomobject]@{
            Zone = $Zone
            Index = $index
            ReceiverName = $receiverName
            DisplayName = $receiverName
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
    $pid = $null
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
        $pid = [string]$player.pid
        $heosModel = [string]$player.model
        $heosVersion = [string]$player.version
        $network = [string]$player.network
        if ([string]::IsNullOrWhiteSpace($service) -and -not [string]::IsNullOrWhiteSpace([string]$player.name)) {
            $service = [string]$player.name
        }

        $media = Invoke-DenonHeosCommand -Command ('heos://player/get_now_playing_media?pid={0}' -f $pid) -Receiver $receiver
        if ($null -ne $media -and $media.heos.result -eq 'success') {
            if ([string]::IsNullOrWhiteSpace($title)) { $title = [string]$media.payload.song }
            if ([string]::IsNullOrWhiteSpace($artist)) { $artist = [string]$media.payload.artist }
            if ([string]::IsNullOrWhiteSpace($album)) { $album = [string]$media.payload.album }
            $station = [string]$media.payload.station
            $serviceName = Get-DenonHeosServiceName -Sid ([string]$media.payload.sid) -Mid ([string]$media.payload.mid)
            if (-not [string]::IsNullOrWhiteSpace($serviceName)) { $service = $serviceName }
            $source = if ($source -eq 'Unavailable') { 'HEOS' } else { '{0}+HEOS' -f $source }
        }

        $playState = Invoke-DenonHeosCommand -Command ('heos://player/get_play_state?pid={0}' -f $pid) -Receiver $receiver
        if ($null -ne $playState -and $playState.heos.result -eq 'success') {
            $message = [string]$playState.heos.message
            if ($message -match '(?:^|[?&])state=([^&]+)') {
                $state = ConvertTo-DenonTransportState -State ([System.Uri]::UnescapeDataString($Matches[1]))
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
        PlayerId = if ([string]::IsNullOrWhiteSpace($pid)) { $null } else { $pid }
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
    'Set-DenonReceiver',
    'Test-DenonReceiver',
    'Get-DenonInfo',
    'Get-DenonStatus',
    'Get-DenonReceiverSummary',
    'Get-DenonNowPlaying',
    'Get-DenonSources',
    'Get-DenonZone2Status',
    'Get-DenonSleep',
    'Show-DenonDashboard',
    'Set-DenonPower',
    'Set-DenonMute',
    'Set-DenonVolume',
    'Step-DenonVolume',
    'Set-DenonSource',
    'Set-DenonZone2Power',
    'Set-DenonZone2Mute',
    'Set-DenonZone2Volume',
    'Step-DenonZone2Volume',
    'Invoke-DenonTelnetCommand'
)
