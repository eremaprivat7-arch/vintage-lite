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

function Assert-VintageReleaseFiles {
    $currentHead = (& git -C $repoRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $currentHead -ne $releaseCommit) {
        throw 'The release checkout changed during publication. Publication stopped.'
    }
    & git -C $repoRoot diff --quiet HEAD -- ThreeOneOSFive/Patches ThreeOneOSSix license-server tools
    if ($LASTEXITCODE -ne 0) {
        throw 'Release files changed. Upload the current Patches folder and prepare a new release bundle.'
    }
    $patchChanges = @(& git -C $repoRoot status --porcelain --untracked-files=all --ignored -- ThreeOneOSFive/Patches)
    if ($LASTEXITCODE -ne 0 -or $patchChanges.Count -ne 0) {
        throw 'The Patches folder differs from the approved release. Upload the updated folder first.'
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
if ($versionNode.InnerText -ne '2.2.7') { throw 'Expected the VintageLite 2.2.7 release files.' }
Assert-VintageReleaseFiles

Push-Location -LiteralPath $serverRoot
try {
    Invoke-VintageCommand -Program 'npm.cmd' -Arguments @('ci', '--no-audit', '--no-fund')
    # Apply this idempotent release-only schema. Do not replay unrelated old
    # reseller migrations or reset licenses, bindings, balances or secrets.
    Invoke-VintageCommand -Program 'npx.cmd' -Arguments @(
        'wrangler', 'd1', 'execute', 'vintage-lite-keys', '--remote', '--yes',
        '--file', 'migrations/0008_release_227.sql'
    )
    Invoke-VintageCommand -Program 'npx.cmd' -Arguments @('wrangler', 'deploy', '--keep-vars')
}
finally {
    Pop-Location
}

Assert-VintageReleaseFiles
Invoke-VintageCommand -Program 'git' -Arguments @(
    '-C', $repoRoot, 'push', '--atomic', 'origin',
    ($releaseCommit + ':refs/heads/main'),
    ($releaseCommit + ':refs/tags/v2.2.7')
)
Write-Host 'Server updated. VintageLite 2.2.7 IPA build started in GitHub Actions.'
