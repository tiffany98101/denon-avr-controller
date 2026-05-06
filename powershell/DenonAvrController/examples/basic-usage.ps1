$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'DenonAvrController.psd1')

# Many Denon receivers use a self-signed HTTPS certificate on port 10443.
# Replace 192.168.1.100 with your AVR's local IP address.
Set-DenonReceiver -IpAddress 192.168.1.100 -SkipCertificateCheck

# Read-only checks first.
Test-DenonReceiver
Get-DenonStatus
Get-DenonSources
Show-DenonDashboard
