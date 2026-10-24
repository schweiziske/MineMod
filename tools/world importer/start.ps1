param(
	[Parameter(ValueFromRemainingArguments = $true)]
	[string[]] $AppArgs
)

$ErrorActionPreference = "Stop"
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$uiScript = Join-Path $toolRoot "world_importer_ui.py"

try {
	& python --version *> $null
	if ($LASTEXITCODE -eq 0) {
		$env:PYTHONUTF8 = "1"
		& python $uiScript @AppArgs
		exit $LASTEXITCODE
	}
}
catch {
	# Fall through to the Windows Python launcher.
}

try {
	& py -3 --version *> $null
	if ($LASTEXITCODE -eq 0) {
		$env:PYTHONUTF8 = "1"
		& py -3 $uiScript @AppArgs
		exit $LASTEXITCODE
	}
}
catch {
	# Fall through to the installation error below.
}

throw "Python 3 was not found. Install Python 3.11 or newer."
