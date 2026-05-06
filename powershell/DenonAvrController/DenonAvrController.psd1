@{
    RootModule = 'DenonAvrController.psm1'
    ModuleVersion = '0.1.0'
    GUID = '7bd4473f-4e98-4bd2-bdb9-07261e1d8a5b'
    Author = 'Denon AVR Controller contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) Denon AVR Controller contributors. All rights reserved.'
    Description = 'Native PowerShell module for controlling Denon AVR receivers over HTTP/XML and TCP sockets.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport = @(
        'Set-DenonReceiver',
        'Test-DenonReceiver',
        'Get-DenonInfo',
        'Get-DenonStatus',
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

    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()

    PrivateData = @{
        PSData = @{
            Tags = @('Denon', 'AVR', 'Receiver', 'PowerShell')
            ProjectUri = 'https://github.com/tiffany98101/denon-avr-controller'
            Prerelease = 'beta'
        }
    }
}
