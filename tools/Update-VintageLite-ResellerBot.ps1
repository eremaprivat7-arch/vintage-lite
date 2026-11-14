[CmdletBinding()]
param()

# Compatibility entry point: this update needs both the admin UI and bot Worker.
& (Join-Path $PSScriptRoot 'Update-VintageLite-BotAccess.ps1')
