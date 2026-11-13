[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$serverRoot = Join-Path $repoRoot 'license-server'
$nodeVersion = [Version]((& node --version).Trim().TrimStart('v'))
if ($LASTEXITCODE -ne 0 -or $nodeVersion -lt [Version]'22.12') {
    throw 'Node.js 22.12 or newer is required for the tested Wrangler version.'
}

function Invoke-VintageCommand {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE. Publication stopped."
    }
}

$releaseCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot read the release commit.' }
$origin = (& git -C $repoRoot config --get remote.origin.url).Trim()
if ($LASTEXITCODE -ne 0 -or $origin -notmatch 'github\.com[:/]eremaprivat7-arch/vintage-lite(?:\.git)?$') {
    throw 'This script must run from the eremaprivat7-arch/vintage-lite checkout.'
}
$plist = [xml](Get-Content -LiteralPath (Join-Path $repoRoot 'ThreeOneOSSix/Info.plist') -Raw)
$versionNode = $plist.SelectSingleNode('/plist/dict/key[text()="CFBundleShortVersionString"]/following-sibling::*[1]')
if ($versionNode.InnerText -ne '2.2.6') { throw 'Expected the VintageLite 2.2.6 release files.' }
& git -C $repoRoot diff --quiet HEAD -- ThreeOneOSSix license-server
if ($LASTEXITCODE -ne 0) { throw 'Release files have local changes. Use the clean release worktree.' }

Push-Location -LiteralPath $serverRoot
try {
    Invoke-VintageCommand -Program 'npm.cmd' -Arguments @('ci', '--no-audit', '--no-fund')
    # Apply this idempotent release-only schema. Do not replay unrelated old
    # reseller migrations or reset licenses, bindings, balances or secrets.
    Invoke-VintageCommand -Program 'npx.cmd' -Arguments @(
        'wrangler', 'd1', 'execute', 'vintage-lite-keys', '--remote',
        '--file', 'migrations/0007_release_discovery.sql'
    )
    Invoke-VintageCommand -Program 'npx.cmd' -Arguments @('wrangler', 'deploy', '--keep-vars')
}
finally {
    Pop-Location
}

Invoke-VintageCommand -Program 'git' -Arguments @(
    '-C', $repoRoot, 'push', '--atomic', 'origin',
    ($releaseCommit + ':refs/heads/main'),
    ($releaseCommit + ':refs/tags/v2.2.6')
)
Write-Host 'Server updated. VintageLite 2.2.6 IPA build started in GitHub Actions.'
