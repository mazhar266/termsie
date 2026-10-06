<#
.SYNOPSIS
    Packages the staged Windows build (placeholder until the full release pipeline lands).
#>
param(
    [ValidateSet("x64", "arm64")] [string]$Arch = "x64",
    [switch]$SkipBuild,
    [switch]$SkipSign
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$version = (Select-String -Path "Sources/TermsieCore/Support/Platform.swift" -Pattern 'static let version = "([0-9.]+)"').Matches[0].Groups[1].Value
if (-not $SkipBuild) { & ./scripts/build-windows.ps1 -Arch $Arch }
$stage = "dist/windows/$Arch/Termsie"
$zip = "dist/windows/Termsie-$version-windows-$Arch.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path $stage -DestinationPath $zip
Write-Host "Wrote $zip"
