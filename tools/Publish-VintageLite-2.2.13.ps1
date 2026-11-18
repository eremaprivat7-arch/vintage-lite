[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

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
        throw 'The release checkout changed. Publication stopped.'
    }
    & git -C $repoRoot diff --quiet HEAD --
    if ($LASTEXITCODE -ne 0) { throw 'Release files changed. Use a clean release checkout.' }
    $patchChanges = @(& git -C $repoRoot status --porcelain --untracked-files=all --ignored -- ThreeOneOSFive/Patches)
    if ($LASTEXITCODE -ne 0 -or $patchChanges.Count -ne 0) {
        throw 'The Patches folder differs from the release. Publication stopped.'
    }
}

$releaseCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot read the release commit.' }
$origin = (& git -C $repoRoot config --get remote.origin.url).Trim()
if ($LASTEXITCODE -ne 0 -or $origin -notmatch 'github\.com[:/]eremaprivat7-arch/vintage-lite(?:\.git)?$') {
    throw 'Run this script from the eremaprivat7-arch/vintage-lite checkout.'
}
$plist = [xml](Get-Content -LiteralPath (Join-Path $repoRoot 'ThreeOneOSSix/Info.plist') -Raw)
$versionNode = $plist.SelectSingleNode('/plist/dict/key[text()="CFBundleShortVersionString"]/following-sibling::*[1]')
$buildNode = $plist.SelectSingleNode('/plist/dict/key[text()="CFBundleVersion"]/following-sibling::*[1]')
if ($versionNode.InnerText -ne '2.2.13' -or $buildNode.InnerText -ne '24') {
    throw 'Expected VintageLite 2.2.13 (24).'
}
Assert-VintageReleaseFiles

# Refuse to publish an older main or replace a tag belonging to another commit.
Invoke-VintageCommand -Program 'git' -Arguments @('-C', $repoRoot, 'fetch', '--no-tags', 'origin', 'refs/heads/main:refs/remotes/origin/main')
& git -C $repoRoot merge-base --is-ancestor refs/remotes/origin/main $releaseCommit
if ($LASTEXITCODE -ne 0) { throw 'Main has new commits missing from this release. Publication stopped.' }
$existingTag = @(& git -C $repoRoot ls-remote origin 'refs/tags/v2.2.13')
if ($LASTEXITCODE -ne 0) { throw 'Cannot verify the release tag.' }
if ($existingTag.Count -gt 0 -and ($existingTag[0] -split '\s+')[0] -ne $releaseCommit) {
    throw 'The v2.2.13 tag already belongs to another commit. Publication stopped.'
}

$ciBranch = 'ci/vintagelite-2.2.13-' + $releaseCommit.Substring(0, 12)
Invoke-VintageCommand -Program 'git' -Arguments @(
    '-C', $repoRoot, 'push', 'origin', ($releaseCommit + ':refs/heads/' + $ciBranch)
)

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$headers = @{ 'User-Agent' = 'VintageLite-release-check'; 'Accept' = 'application/vnd.github+json' }
$query = '?head_sha=' + $releaseCommit + '&event=push&branch=' + [Uri]::EscapeDataString($ciBranch) + '&per_page=5'
$runsURL = 'https://api.github.com/repos/eremaprivat7-arch/vintage-lite/actions/workflows/build-ipa.yml/runs' + $query
$deadline = (Get-Date).AddMinutes(40)
$verified = $false
$failures = 0
$polls = 0
Write-Host 'Checking the complete iPhone build in GitHub Actions. This can take several minutes.'
while ((Get-Date) -lt $deadline) {
    try {
        $response = Invoke-RestMethod -Uri $runsURL -Headers $headers -TimeoutSec 20
        $failures = 0
    } catch {
        $failures++
        if ($failures -ge 3) { throw 'Cannot verify GitHub Actions. Main and the release tag were not pushed.' }
        Write-Host 'Could not read the CI status; retrying shortly.'
        Start-Sleep -Seconds 30
        continue
    }
    $run = $response.workflow_runs | Where-Object {
        $_.head_sha -eq $releaseCommit -and $_.head_branch -eq $ciBranch -and $_.event -eq 'push'
    } | Sort-Object run_number -Descending | Select-Object -First 1
    if ($null -ne $run) {
        Write-Host ('CI: ' + $run.status + ' | ' + $run.html_url)
        if ($run.status -eq 'completed') {
            if ($run.conclusion -ne 'success') {
                throw ('CI failed (' + $run.conclusion + '). Publication stopped. Open ' + $run.html_url)
            }
            $verified = $true
            break
        }
    } else { Write-Host 'Waiting for the CI run to appear...' }
    $polls++
    Start-Sleep -Seconds $(if ($polls -le 6) { 30 } else { 60 })
}
if (!$verified) { throw 'Timed out waiting for CI. Main and the release tag were not pushed.' }

Assert-VintageReleaseFiles
Invoke-VintageCommand -Program 'git' -Arguments @(
    '-C', $repoRoot, 'push', '--atomic', 'origin',
    ($releaseCommit + ':refs/heads/main'), ($releaseCommit + ':refs/tags/v2.2.13')
)
Write-Host 'CI passed. VintageLite 2.2.13 publication started in GitHub Actions.'
