#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads the anytype-heart middleware (grpc-server) and installs it into dist/ as anytypeHelper.exe.

.DESCRIPTION
    PowerShell translation of ./update.sh, targeting the "windows-latest" platform.
    The middleware version is read from ./middleware.version.

.PARAMETER Platform
    Must be "windows-latest" (the only supported platform in this script).

.PARAMETER Arch
    Accepted for parity with update.sh, but unused on windows-latest (arch is always "windows").

.EXAMPLE
    .\update.ps1
#>

param(
    [string]$Platform = 'windows-latest',
    [string]$Arch = 'windows'
)

$ErrorActionPreference = 'Stop'

# Older Windows PowerShell defaults may not include TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repo   = 'anyproto/anytype-heart'
$File   = 'addon.zip'
$GitHub = 'api.github.com'

$Folder = 'dist'

Write-Host "Platform: $Platform"
Write-Host "Arch: $Arch"
Write-Host "Folder: $Folder"
Write-Host ""

if ([string]::IsNullOrEmpty($Arch)) {
    Write-Host "ERROR: arch not found"
    exit 1
}

$mwv = (Get-Content -Raw middleware.version).Trim()

Write-Host "Querying release v$mwv ..."
$release = Invoke-RestMethod `
    -Uri "https://$GitHub/repos/$Repo/releases/tags/v$mwv" `
    -Headers @{ Accept = 'application/vnd.github.v3+json' }

$tag   = $release.tag_name
$asset = $release.assets |
    Where-Object { $_.name -match "js_(nightly|v[0-9]+.[0-9]+.[0-9]+([^_]+)?)_$Arch" } |
    Select-Object -First 1

if (-not $asset) {
    Write-Host "ERROR: version not found"
    exit 1
}

$assetId = $asset.id

Write-Host "Version: $tag"
Write-Host "Found asset: $assetId"
Write-Host -NoNewline "Downloading file..."

Invoke-WebRequest `
    -Uri "https://$GitHub/repos/$Repo/releases/assets/$assetId" `
    -Headers @{ Accept = 'application/octet-stream' } `
    -OutFile $File

Write-Host "Done"

Write-Host -NoNewline "Uncompressing... "
Expand-Archive -Path $File -DestinationPath . -Force
Write-Host "Done"

Write-Host "Moving... "
Move-Item -Path 'grpc-server.exe' -Destination (Join-Path $Folder 'anytypeHelper.exe') -Force

Remove-Item -Path 'dist/lib/pb' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'dist/lib/pkg' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'dist/lib/protos' -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path 'dist/lib/json/generated/*.json' -ErrorAction SilentlyContinue | Remove-Item -Force

Move-Item -Path 'protobuf/*' -Destination 'dist/lib/' -Force
New-Item -ItemType Directory -Force -Path 'dist/lib/json/generated' | Out-Null
Move-Item -Path 'json/*' -Destination 'dist/lib/json/generated' -Force

Remove-Item -Path 'protobuf' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'relations' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'json' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $File -Force -ErrorAction SilentlyContinue

Write-Host "Done"
Write-Host ""
