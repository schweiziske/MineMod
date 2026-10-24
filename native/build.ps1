param(
    [ValidateSet("Debug", "Release", "Release_Final")]
    [string]$Configuration = "Release_Final",
    [ValidateSet("auto", "public", "x86-64")]
    [string]$Branch = "auto",
    [ValidateSet("x64", "x86")]
    [string]$Architecture = "x64",
    [string]$OutputDirectory,
    [switch]$Tests
)
$ErrorActionPreference = "Stop"
if ($Branch -ne "public" -and $Architecture -ne "x64") {
    throw "Auto/beta builds require -Architecture x64. Use -Branch public for x86."
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) { throw "Visual Studio Installer/vswhere is required." }
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw "MSVC x64 build tools are required." }
$devShell = Join-Path $vs "Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
if (-not (Test-Path -LiteralPath $devShell)) { throw "Visual Studio Developer PowerShell is required." }
Import-Module $devShell
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments "-arch=$Architecture -host_arch=x64"

$cmake = Join-Path $vs "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
$ninja = Join-Path $vs "Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"
if (-not (Test-Path -LiteralPath $cmake)) { throw "Install the Visual Studio CMake component." }
if (-not (Test-Path -LiteralPath $ninja)) { throw "Install the Visual Studio Ninja component." }
$branchName = switch ($Branch) { "auto" { "auto" }; "public" { "public" }; "x86-64" { "beta" } }
$configurationName = $Configuration.ToLowerInvariant().Replace("_", "-")
$preset = "$branchName-$configurationName"
if ($Architecture -eq "x86") { $preset = "$branchName-x86-$configurationName" }
$testOption = if ($Tests) { "ON" } else { "OFF" }
$configureArguments = @("--preset", $preset, "-DCMAKE_MAKE_PROGRAM=$ninja", "-DMCSWEP_BUILD_TESTS=$testOption")
if ($OutputDirectory) {
    $output = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $OutputDirectory))
    if (-not $output.StartsWith($PSScriptRoot + "\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "OutputDirectory must stay inside native/."
    }
    $configureArguments += "-DMCSWEP_OUTPUT_DIRECTORY=$output"
} else {
    # Reset an earlier override when reusing a preset's cache.
    $configureArguments += "-DMCSWEP_OUTPUT_DIRECTORY=$PSScriptRoot/build/$Architecture/$preset/bin"
}
Push-Location $PSScriptRoot
try {
    & $cmake @configureArguments
    if ($LASTEXITCODE -ne 0) { throw "Native CMake configuration failed ($LASTEXITCODE)." }
    & $cmake --build --preset $preset --parallel
    if ($LASTEXITCODE -ne 0) { throw "Native module build failed ($LASTEXITCODE)." }
    if ($Tests) {
        $ctest = Join-Path (Split-Path $cmake) "ctest.exe"
        & $ctest --test-dir "$PSScriptRoot/build/$Architecture/$preset" --output-on-failure
        if ($LASTEXITCODE -ne 0) { throw "Native core tests failed ($LASTEXITCODE)." }
    }
} finally {
    Pop-Location
}
