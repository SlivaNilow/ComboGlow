<#
    Cuts a release in one step: bumps the version in the .toc, commits that,
    tags it and pushes both.

        .\release.ps1 1.0.1

    Everything else stays a normal push-when-ready workflow; this only marks
    the point that users and CurseForge take.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# A release should be a deliberate line under finished work, so anything still
# uncommitted is a mistake worth stopping for rather than sweeping in.
$dirty = git status --porcelain
if ($dirty) {
    Write-Host "Working tree is not clean. Commit or stash first:" -ForegroundColor Yellow
    $dirty | ForEach-Object { Write-Host "  $_" }
    exit 1
}

$tag = "v$Version"
if ((git tag -l $tag)) {
    Write-Host "Tag $tag already exists." -ForegroundColor Yellow
    exit 1
}

$toc = 'ComboGlow.toc'
$text = Get-Content $toc -Raw
$updated = [regex]::Replace($text, '(?m)^## Version:.*$', "## Version: $Version")
if ($updated -eq $text) {
    Write-Host "No '## Version:' line found in $toc." -ForegroundColor Yellow
    exit 1
}
Set-Content -Path $toc -Value $updated -Encoding UTF8 -NoNewline

git add $toc
git commit -m "Release $Version"
git tag -a $tag -m $Version
git push
git push origin $tag

Write-Host ""
Write-Host "Released $tag." -ForegroundColor Green
Write-Host "With automatic packaging off, upload the zip by hand -- see PUBLISHING.md."
