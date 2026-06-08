@{
    RootModule = 'DenonAvrController.psm1'
    ModuleVersion = '1.2.0'
    GUID = '7bd4473f-4e98-4bd2-bdb9-07261e1d8a5b'
    Author = 'Denon AVR Controller contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) Denon AVR Controller contributors. All rights reserved.'
    Description = 'Native PowerShell module for controlling and inspecting Denon AVR receivers over HTTP/XML, HEOS status, TCP sockets, and Bash-parity helper workflows.'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')

    FunctionsToExport = @(
        'Invoke-DenonCommand',
        'Set-DenonReceiver',
        'Set-DenonReceiverIp',
        'Find-DenonReceiver',
        'Test-DenonReceiver',
        'Invoke-DenonDoctor',
        'Get-DenonInfo',
        'Get-DenonSignalDebug',
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
        'Invoke-DenonVolumeFade',
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

    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()

    PrivateData = @{
        PSData = @{
            Tags = @('Denon', 'AVR', 'Receiver', 'PowerShell')
            ProjectUri = 'https://github.com/tiffany98101/denon-avr-controller'
            Prerelease = 'beta5'
        }
    }
}
