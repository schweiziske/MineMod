param(
    [ValidateSet("Debug", "Release", "Release_Final")]
    [string]$Configuration = "Release_Final",
    [string]$OutputDirectory,
    [switch]$Tests
)
$ErrorActionPreference = "Stop"
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) { throw "Visual Studio Installer/vswhere is required." }
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw "MSVC x64 build tools are required." }
$msbuild = Join-Path $vs "MSBuild\Current\Bin\MSBuild.exe"
$buildArguments = @("/m", "/nologo", "/p:Configuration=$Configuration", "/p:Platform=x64", "/v:minimal")
if ($OutputDirectory) {
    $output = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $OutputDirectory))
    if (-not $output.StartsWith($PSScriptRoot + "\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "OutputDirectory must stay inside native/."
    }
    $buildArguments += "/p:OutDir=$output/"
}
& $msbuild (Join-Path $PSScriptRoot "mcswep_native_mesh.vcxproj") @buildArguments
if ($LASTEXITCODE -ne 0) { throw "Native module build failed ($LASTEXITCODE)." }
if ($Tests) {
    $cmake = Join-Path $vs "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    if (-not (Test-Path -LiteralPath $cmake)) { throw "Install the Visual Studio CMake component." }
    $build = Join-Path $PSScriptRoot "build\x64\tests"
    & $cmake -S (Join-Path $PSScriptRoot "tests") -B $build -G "Visual Studio 17 2022" -A x64
    if ($LASTEXITCODE -ne 0) { throw "Native test configuration failed." }
    & $cmake --build $build --config Release --parallel
    if ($LASTEXITCODE -ne 0) { throw "Native test build failed." }
    $ctest = Join-Path (Split-Path $cmake) "ctest.exe"
    & $ctest --test-dir $build -C Release --output-on-failure
    if ($LASTEXITCODE -ne 0) { throw "Native core tests failed." }
}
