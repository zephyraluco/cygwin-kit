[CmdletBinding()]
param(
    [string]$WorkRoot = (Join-Path $env:TEMP 'cygwin-build-work'),
    [string]$BuildRoot = 'C:\cygwin-build',
    [string]$Runtime = 'C:\cygwin',
    [string]$StageRoot = '',
    [string]$Archive = (Join-Path $env:RUNNER_TEMP 'cygwin-x86_64.tar.gz')
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Requires Windows PowerShell 7.' }
function Run([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE) { throw "$Program failed: $LASTEXITCODE" }
}
& "$PSScriptRoot/install-cygwin.ps1" -Root $Runtime
Write-Host 'Integrating compiled commands with the build Cygwin environment'
$script = & "$BuildRoot/bin/cygpath.exe" -u "$PSScriptRoot/package-cygwin.sh"
if ($LASTEXITCODE) { throw 'cygpath failed' }
Run "$BuildRoot/bin/bash.exe" @('--login', $script, $WorkRoot, $Runtime)

if (-not $StageRoot) { $StageRoot = Join-Path $WorkRoot ("stage-$([guid]::NewGuid())/cygwin") }
Write-Host "Creating minimal runtime: $StageRoot"
$stagingScript = & "$BuildRoot/bin/cygpath.exe" -u "$PSScriptRoot/stage-runtime.sh"
if ($LASTEXITCODE) { throw 'Staging cygpath failed' }
Run "$BuildRoot/bin/bash.exe" @('--login', $stagingScript, $Runtime, $StageRoot)

# Start the staged runtime from PowerShell, never from another Cygwin process.
Write-Host 'Validating minimal runtime (ripgrep ABI only)'
$testScript = & "$BuildRoot/bin/cygpath.exe" -u "$PSScriptRoot/test-runtime.sh"
if ($LASTEXITCODE) { throw 'Test script cygpath failed' }
Run "$StageRoot/bin/bash.exe" @('--login', $testScript, $StageRoot)
# Remove only temporary homes created in this fresh staging tree by validation.
Get-ChildItem "$StageRoot/home" -Force | Remove-Item -Recurse -Force

Write-Host 'Archiving the minimal runtime'
$Archive = [IO.Path]::GetFullPath($Archive)
New-Item -ItemType Directory -Force (Split-Path $Archive) | Out-Null
$archivePath = & "$Runtime/bin/cygpath.exe" -u $Archive
if ($LASTEXITCODE) { throw 'Archive cygpath failed' }
$parent = & "$Runtime/bin/cygpath.exe" -u (Split-Path $StageRoot)
if ($LASTEXITCODE) { throw 'Runtime parent cygpath failed' }
$previousPath = $env:PATH
try {
    $env:PATH = "$Runtime\bin;$env:PATH"
    Run "$Runtime/bin/tar.exe" @('-czf', $archivePath, '-C', $parent, (Split-Path $StageRoot -Leaf))
    & "$Runtime/bin/tar.exe" -tzf $archivePath > "$Archive.files.txt"
    if ($LASTEXITCODE) { throw "Archive validation failed: $LASTEXITCODE" }
} finally { $env:PATH = $previousPath }
