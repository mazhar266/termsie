<#
.SYNOPSIS
    Builds Termsie for Windows and stages a runnable folder in dist/windows/<arch>/Termsie.

.DESCRIPTION
    1. Writes a resource script with the version, the icon and the application manifest, and
       compiles it with the Windows SDK's rc.exe, so Termsie.exe carries its own icon and
       declares per-monitor DPI awareness, UTF-8 and the version-6 common controls.
    2. swift build, for x64 or arm64.
    3. Copies the executable, the Swift runtime and the Visual C++ runtime into one folder, which
       then runs on a machine with neither installed. Optionally adds the redistributable
       ConPTY (conpty.dll and OpenConsole.exe) that Windows Terminal ships.

    Requires the Swift toolchain for Windows and Visual Studio 2022 (or its Build Tools) with
    the Windows 11 SDK and the C++ tools, as listed at https://www.swift.org/install/windows/.

        ./scripts/build-windows.ps1                      # release, x64
        ./scripts/build-windows.ps1 -Configuration debug
        ./scripts/build-windows.ps1 -Arch arm64
        ./scripts/build-windows.ps1 -Conpty              # bundle the current ConPTY
#>
param(
    [ValidateSet("release", "debug")] [string]$Configuration = "release",
    [ValidateSet("x64", "arm64")] [string]$Arch = "x64",
    [switch]$Conpty,
    [string]$ConptyVersion = "1.22.250204002"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Say($message) { Write-Host "`n==> $message" -ForegroundColor Cyan }

$version = (Select-String -Path "Sources/TermsieCore/Support/Platform.swift" -Pattern 'static let version = "([0-9.]+)"').Matches[0].Groups[1].Value
Say "Termsie $version, $Configuration, $Arch"

# ------------------------------------------------------------------------------ resources
function Find-WindowsSdkTool([string]$name) {
    $kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (-not (Test-Path $kits)) { return $null }
    $hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    Get-ChildItem $kits -Directory | Where-Object { $_.Name -match '^10\.' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName "$hostArch\$name" } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}

$resDir = Join-Path $root ".build\windows-resources"
New-Item -ItemType Directory -Force $resDir | Out-Null
$res = Join-Path $resDir "termsie-$Arch.res"
$rc = Find-WindowsSdkTool "rc.exe"
$linkerFlags = @()
if ($rc) {
    $parts = ($version.Split(".") + @("0", "0", "0", "0"))[0..3] -join ","
    $icon = (Resolve-Path "Resources/Windows/Termsie.ico").Path.Replace("\", "\\")
    $manifest = (Resolve-Path "Resources/Windows/Termsie.manifest").Path.Replace("\", "\\")
    @"
1 ICON "$icon"
1 24 "$manifest"
1 VERSIONINFO
FILEVERSION $parts
PRODUCTVERSION $parts
FILEFLAGSMASK 0x3fL
FILEFLAGS 0x0L
FILEOS 0x40004
FILETYPE 0x1
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904b0"
    BEGIN
      VALUE "CompanyName", "Termsie"
      VALUE "FileDescription", "Termsie"
      VALUE "FileVersion", "$version"
      VALUE "InternalName", "Termsie"
      VALUE "LegalCopyright", "Apache License 2.0"
      VALUE "OriginalFilename", "Termsie.exe"
      VALUE "ProductName", "Termsie"
      VALUE "ProductVersion", "$version"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
"@ | Set-Content -Encoding ascii (Join-Path $resDir "termsie.rc")
    & $rc /nologo /fo $res (Join-Path $resDir "termsie.rc")
    if ($LASTEXITCODE -ne 0) { throw "rc.exe failed" }
    $linkerFlags = @("-Xlinker", $res)
    Write-Host "  resources: $res"
} else {
    Write-Warning "rc.exe not found: Termsie.exe will have no embedded icon, version or manifest"
}

# ---------------------------------------------------------------------------------- build
. (Join-Path $PSScriptRoot "swiftterm-build-info.ps1")
$tripleArgs = @()
if ($Arch -eq "arm64") { $tripleArgs = @("--triple", "aarch64-unknown-windows-msvc") }
Say "swift build"
& swift build -c $Configuration --product Termsie @tripleArgs @linkerFlags
if ($LASTEXITCODE -ne 0) { throw "swift build failed" }
$bin = (& swift build -c $Configuration --product Termsie @tripleArgs --show-bin-path).Trim()

# ---------------------------------------------------------------------------------- stage
$stage = Join-Path $root "dist\windows\$Arch\Termsie"
Say "Staging $stage"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item (Join-Path $bin "Termsie.exe") $stage
Copy-Item "Resources/Windows/Termsie.ico" $stage
Copy-Item "LICENSE" $stage
Get-ChildItem $bin -Directory -Filter "*.resources" -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item $_.FullName $stage -Recurse
}

# The Swift runtime: every DLL beside swiftCore.dll in the toolchain's runtime folder.
function Find-SwiftRuntime {
    $found = & where.exe swiftCore.dll 2>$null | Select-Object -First 1
    if ($found) { return Split-Path -Parent $found }
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Swift\Runtimes",
        "$env:ProgramFiles\Swift\Runtimes",
        "$env:SystemDrive\Library\Swift-development\Runtimes"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $dll = Get-ChildItem $c -Recurse -Filter swiftCore.dll -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($dll) { return $dll.DirectoryName }
        }
    }
    return $null
}
$runtime = Find-SwiftRuntime
if ($Arch -ne "x64" -and $runtime) {
    # Cross builds take the target's runtime from the SDK rather than the host's.
    $sdkBin = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Platforms" -Recurse -Directory -Filter "bin" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "aarch64|arm64" -and (Test-Path (Join-Path $_.FullName "swiftCore.dll")) } |
        Select-Object -First 1
    $runtime = if ($sdkBin) { $sdkBin.FullName } else { $null }
}
if ($runtime) {
    Write-Host "  Swift runtime: $runtime"
    Get-ChildItem $runtime -Filter *.dll | Copy-Item -Destination $stage
} else {
    Write-Warning "Swift runtime DLLs not found: the staged app needs the Swift runtime installed"
}

# The Visual C++ runtime, deployed app-locally as Microsoft allows for these files.
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$crtCopied = $false
if (Test-Path $vswhere) {
    $vs = & $vswhere -latest -products * -property installationPath
    if ($vs) {
        $redist = Get-ChildItem (Join-Path $vs "VC\Redist\MSVC") -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d' } | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
        if ($redist) {
            $crt = Get-ChildItem (Join-Path $redist.FullName $Arch) -Directory -Filter "Microsoft.VC*.CRT" -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($crt) {
                Get-ChildItem $crt.FullName -Filter *.dll | Copy-Item -Destination $stage
                $crtCopied = $true
                Write-Host "  VC runtime: $($crt.FullName)"
            }
        }
    }
}
if (-not $crtCopied) { Write-Warning "Visual C++ runtime not found: the staged app needs the VC++ redistributable" }

# ------------------------------------------------------------------------- optional ConPTY
if ($Conpty) {
    Say "Adding Microsoft.Windows.Console.ConPTY $ConptyVersion"
    $pkg = Join-Path $root ".build\conpty-$ConptyVersion.nupkg"
    if (-not (Test-Path $pkg)) {
        Invoke-WebRequest "https://www.nuget.org/api/v2/package/Microsoft.Windows.Console.ConPTY/$ConptyVersion" -OutFile $pkg
    }
    $unpacked = Join-Path $root ".build\conpty-$ConptyVersion"
    if (-not (Test-Path $unpacked)) { Expand-Archive $pkg $unpacked }
    $rid = "win-$Arch"
    Copy-Item (Join-Path $unpacked "runtimes\$rid\native\conpty.dll") $stage
    Copy-Item (Join-Path $unpacked "build\native\runtimes\$Arch\OpenConsole.exe") $stage -ErrorAction SilentlyContinue
    if (-not (Test-Path (Join-Path $stage "OpenConsole.exe"))) {
        Get-ChildItem $unpacked -Recurse -Filter OpenConsole.exe | Where-Object { $_.FullName -match $Arch } |
            Select-Object -First 1 | Copy-Item -Destination $stage
    }
}

$size = "{0:N1} MB" -f ((Get-ChildItem $stage -Recurse | Measure-Object Length -Sum).Sum / 1MB)
Say "Built $stage ($size)"
