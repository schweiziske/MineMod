param(
    [string]$CompilerDir = 'D:\steam\steamapps\common\GarrysMod\bin',
    [string]$SourceEngineDir = 'D:\code\source-engine'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$destination = Join-Path $PSScriptRoot 'toolchain'
$inputs = @()
foreach ($name in @('shadercompile.exe', 'shadercompile_dll.dll', 'filesystem_stdio.dll',
    'steam_api.dll', 'tier0.dll', 'vstdlib.dll', 'd3dcompiler_43.dll')) {
    $inputs += Join-Path $CompilerDir $name
}
foreach ($name in @('fxc.exe', 'dx_proxy.dll')) {
    $inputs += Join-Path $SourceEngineDir ('dx9sdk\utilities\' + $name)
}
$inputs += Join-Path $SourceEngineDir 'devtools\bin\d3dx9_33.dll'
foreach ($name in @('common_vs_fxc.h', 'common_ps_fxc.h', 'common_fxc.h',
    'common_pragmas.h', 'common_hlsl_cpp_consts.h')) {
    $inputs += Join-Path $SourceEngineDir ('materialsystem\stdshaders\' + $name)
}
foreach ($inputPath in $inputs) {
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        throw "Missing compiler dependency: $inputPath"
    }
}
New-Item -ItemType Directory -Path $destination -Force | Out-Null
foreach ($inputPath in $inputs) {
    Copy-Item -LiteralPath $inputPath -Destination $destination -Force
}
Write-Host "Prepared $($inputs.Count) compiler dependencies in $destination"
