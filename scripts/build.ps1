[CmdletBinding()]
param(
    [string]$WorkRoot = (Join-Path $env:TEMP 'cygwin-build-work'),
    [string]$BuildRoot = 'C:\cygwin-build'
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Requires Windows PowerShell 7.' }
New-Item -ItemType Directory -Force $WorkRoot | Out-Null
& "$PSScriptRoot/install-cygwin.ps1" -Root $BuildRoot -AdditionalPackages 'gcc-core,binutils'
& "$PSScriptRoot/build-cygwin-commands.ps1" -Source (Join-Path $WorkRoot 'ripgrep') -BuildRoot $BuildRoot
& "$PSScriptRoot/build-cygwin-commands.ps1" -Command fd -Source (Join-Path $WorkRoot 'fd') -BuildRoot $BuildRoot
