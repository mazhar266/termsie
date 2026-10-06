<#
.SYNOPSIS
    Drives the Windows app headlessly and checks what it does.

.DESCRIPTION
    Every run uses a throwaway XDG_CONFIG_HOME, so the user's real configuration, workspaces and
    Credential Manager are never touched (secrets go to a JSON file through TERMSIE_SECRETS_FILE).
    Screenshots and logs land in -Out, for a person to look at when a check fails.

        ./scripts/test-windows.ps1 -Exe dist/windows/x64/Termsie/Termsie.exe
#>
param(
    [string]$Exe = "dist/windows/x64/Termsie/Termsie.exe",
    [string]$Out = "test-output"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$Exe = (Resolve-Path $Exe).Path
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$script:failures = 0

function Ok($label) { Write-Host "  ok   $label" -ForegroundColor Green }
function Bad($label, $detail) {
    Write-Host "  FAIL $label" -ForegroundColor Red
    if ($detail) { Write-Host "       $detail" }
    $script:failures++
}
function Check($label, [bool]$condition, $detail = $null) { if ($condition) { Ok $label } else { Bad $label $detail } }

function Quote([string]$arg) {
    if ($arg -notmatch '[\s"]') { return $arg }
    return '"' + ($arg -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# Runs the app with a fresh config folder and returns its log.
function Invoke-Termsie([string]$name, [string[]]$arguments, [int]$timeout = 90, [string]$config = $null) {
    $fixture = Join-Path $Out "$name-config"
    if (-not $config) {
        if (Test-Path $fixture) { Remove-Item -Recurse -Force $fixture }
        New-Item -ItemType Directory -Force (Join-Path $fixture "termsie") | Out-Null
    } else {
        $fixture = $config
    }
    $log = Join-Path $Out "$name.log"
    if (Test-Path $log) { Remove-Item $log }
    $env:XDG_CONFIG_HOME = $fixture
    $env:TERMSIE_SECRETS_FILE = Join-Path $fixture "secrets.json"
    $all = @($arguments) + @("--log", $log)
    $line = ($all | ForEach-Object { Quote $_ }) -join " "
    $p = Start-Process -FilePath $Exe -ArgumentList $line -PassThru
    if (-not $p.WaitForExit($timeout * 1000)) {
        $p.Kill()
        Bad "$name finished within $timeout s"
    }
    if (Test-Path $log) { return Get-Content -Raw $log }
    return ""
}

Write-Host "`n== a shell runs in a pseudo console and its output is drawn"
$log = Invoke-Termsie "spike" @("--snapshot", (Join-Path $Out "spike.png"), "--type", "Write-Output ('termsie'+'-ok')\r",
                                "--wait", "10", "--quit")
Write-Host $log
Check "snapshot written" ($log -match "snapshot=ok")
Check "PNG exists" (Test-Path (Join-Path $Out "spike.png"))
Check "the shell's output reached the screen" ($log -match "(?m)^termsie-ok\s*$") "screen did not show termsie-ok"

if ($script:failures -gt 0) {
    Write-Host "`n$($script:failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall checks passed" -ForegroundColor Green
