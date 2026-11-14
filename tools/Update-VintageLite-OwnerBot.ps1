[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$serverRoot = Join-Path $repoRoot 'license-server'
$nodeVersion = [Version]((& node --version).Trim().TrimStart('v'))
if ($LASTEXITCODE -ne 0 -or $nodeVersion -lt [Version]'22.12') {
    throw 'Node.js 22.12 or newer is required.'
}

function Invoke-VintageCommand {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE. Update stopped." }
}

function Assert-VintageBotFiles {
    $currentHead = (& git -C $repoRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $currentHead -ne $updateCommit) { throw 'The update checkout changed.' }
    & git -C $repoRoot diff --quiet HEAD --
    if ($LASTEXITCODE -ne 0) { throw 'Use the clean owner-bot update checkout.' }
}

$updateCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot read the update commit.' }
$origin = (& git -C $repoRoot config --get remote.origin.url).Trim()
if ($LASTEXITCODE -ne 0 -or $origin -notmatch 'github\.com[:/]eremaprivat7-arch/vintage-lite(?:\.git)?$') {
    throw 'Run this script from the eremaprivat7-arch/vintage-lite checkout.'
}
$config = Get-Content -LiteralPath (Join-Path $repoRoot 'reseller-bot/wrangler.jsonc') -Raw | ConvertFrom-Json
if ($config.name -ne 'vintage-lite-reseller') { throw 'Unexpected bot Worker name.' }
Assert-VintageBotFiles

# Stop before deployment if main has changes that are absent from this update.
Invoke-VintageCommand -Program 'git' -Arguments @('-C', $repoRoot, 'fetch', 'origin', 'main')
& git -C $repoRoot merge-base --is-ancestor FETCH_HEAD $updateCommit
if ($LASTEXITCODE -ne 0) { throw 'Main changed since this update was prepared. Update stopped before deployment.' }

Invoke-VintageCommand -Program 'node' -Arguments @('--experimental-sqlite', (Join-Path $repoRoot 'Tests/bonus_bot.test.mjs'))
Push-Location -LiteralPath $serverRoot
try {
    Invoke-VintageCommand -Program 'npm.cmd' -Arguments @('ci', '--no-audit', '--no-fund')
    Assert-VintageBotFiles
    # Keep the configured ADMIN_ID, bot token, key secret and webhook.
    # Do not replay schema.sql or change existing prices and balances.
    Invoke-VintageCommand -Program 'npx.cmd' -Arguments @(
        'wrangler', 'deploy', '--config', '../reseller-bot/wrangler.jsonc', '--keep-vars'
    )
}
finally { Pop-Location }

Assert-VintageBotFiles
Invoke-VintageCommand -Program 'git' -Arguments @('-C', $repoRoot, 'push', 'origin', ($updateCommit + ':refs/heads/main'))
Write-Host 'Owner-only bot purchases updated. Send /start to refresh your menu.'
