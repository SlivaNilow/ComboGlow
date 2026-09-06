<#
    Copies the addon into the game, so the repository can live outside it.

        .\sync.ps1

    The repository used to sit in Interface\AddOns itself, which is convenient
    right up until something replaces that folder -- the CurseForge app does
    exactly that on Update, and it took .git and every ignored file with it.
    Working here and copying in costs one command and cannot lose anything.

    Only what ships is copied, so the game folder ends up matching the zip:
    no .git, no notes, no build scripts. Nothing is deleted at the far end
    beyond the files being replaced, so a stray file there is harmless.
#>

param(
    [string]$GamePath = 'E:\World of Warcraft\_retail_\Interface\AddOns\ComboGlow'
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# The same set the release archive carries.
$patterns = @('*.lua', '*.xml', '*.toc', 'icon.tga', 'logo*.png',
              'README.md', 'CHANGELOG.md', 'LICENSE', 'INTEGRATION.md')

if (-not (Test-Path $GamePath)) {
    New-Item -ItemType Directory -Path $GamePath -Force | Out-Null
    Write-Host "Created $GamePath"
}

$n = 0
foreach ($p in $patterns) {
    foreach ($f in Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue) {
        Copy-Item -Path $f.FullName -Destination $GamePath -Force
        $n++
    }
}

Write-Host "Copied $n files to $GamePath" -ForegroundColor Green
Write-Host "/reload in game to pick them up."
