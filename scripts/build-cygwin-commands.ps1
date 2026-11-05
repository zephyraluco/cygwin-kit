[CmdletBinding()]
param(
    [ValidateSet('ripgrep')][string]$Command = 'ripgrep',
    [Parameter(Mandatory)][string]$Source,
    [string]$BuildRoot = 'C:\cygwin-build'
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Requires Windows PowerShell 7 and Cygwin GCC.' }
# Add command-specific versions here; compilation and ABI checks are shared.
switch ($Command) {
    'ripgrep' {
        $repository = 'BurntSushi/ripgrep'
        $commit = 'af60c2de9d85e7f3d81c78601669468cf02dabab'
        $binary = 'rg'
    }
}
$toolchain = 'nightly-2025-11-01'
$target = 'x86_64-pc-cygwin'
function Run([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed: $LASTEXITCODE" }
}
$existing = Test-Path $Source
if (-not $existing) { Run git @('clone', '--config', 'core.autocrlf=false', '--no-checkout', "https://github.com/$repository.git", $Source) }
$Source = (Resolve-Path $Source).Path
if ($existing) { Run git @('-C', $Source, 'diff', '--exit-code', 'HEAD', '--') }
Run git @('-C', $Source, 'fetch', '--depth=1', 'origin', $commit)
Run git @('-C', $Source, 'checkout', '--detach', $commit)
Run rustup @('toolchain', 'install', $toolchain, '--profile', 'minimal', '--component', 'rust-src')
$settings = @{
    CARGO_TARGET_X86_64_PC_CYGWIN_LINKER = "$BuildRoot\bin\gcc.exe"
    CC_x86_64_pc_cygwin = "$BuildRoot\bin\gcc.exe"
    AR_x86_64_pc_cygwin = "$BuildRoot\bin\ar.exe"
    CARGO_BUILD_JOBS = '2'
    CARGO_PROFILE_RELEASE_DEBUG = '0'
    CARGO_TARGET_DIR = "$Source\target"
    PATH = "$BuildRoot\bin;$env:PATH"
}
$previous = @{}
foreach ($name in $settings.Keys) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $settings[$name], 'Process')
}
Push-Location $Source
try {
    Run cargo @("+$toolchain", 'build', '--locked', '--release', '--target', $target, '-Zbuild-std=std,panic_abort', '--bin', $binary)
    $exe = "$Source\target\$target\release\$binary.exe"
    Run "$BuildRoot\bin\strip.exe" @('--strip-debug', $exe)
    $headers = & "$BuildRoot\bin\objdump.exe" -p $exe
    if ($LASTEXITCODE -ne 0 -or ($headers -join "`n") -notmatch 'Magic\s+020b' -or
        ($headers -join "`n") -notmatch 'Subsystem\s+00000003' -or
        ($headers -join "`n") -notmatch 'DLL Name: cygwin1\.dll' -or
        ($headers -join "`n") -notmatch '\s_dll_crt0\s') { throw 'Cygwin PE32+ ABI check failed' }
    if (($headers -join "`n") -match 'DLL Name: (msvcrt|ucrtbase|vcruntime[^\s]*)\.dll') { throw 'Unexpected native Windows C runtime' }
    $file = & "$BuildRoot\bin\objdump.exe" -f $exe
    if ($LASTEXITCODE -ne 0 -or ($file -join "`n") -notmatch 'architecture: i386:x86-64') { throw 'Wrong machine architecture' }
    Run git @('diff', '--exit-code', 'HEAD', '--')
} finally {
    Pop-Location
    foreach ($name in $settings.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
}
