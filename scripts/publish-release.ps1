[CmdletBinding()]
param([string]$Archive = (Join-Path $env:RUNNER_TEMP 'cygwin-x86_64.tar.gz'))
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_REF_TYPE -ne 'tag') { throw 'Releases require a tag.' }
$tag = $env:GITHUB_REF_NAME
$checksum = "$Archive.sha256"
$hash = (Get-FileHash $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $([IO.Path]::GetFileName($Archive))" | Set-Content $checksum -Encoding ascii
$notes = Join-Path (Split-Path $Archive) 'release-notes.md'
@'
Cygwin environment with ripgrep 15.1.0, OpenSSH, sshpass, wget and curl.

Download cygwin-x86_64.tar.gz and its SHA-256 checksum. Extract on Windows.
ripgrep is checked for the Cygwin ABI only; its runtime behavior is not tested.
The runtime contains only selected commands and their DLL dependencies.
Debug information, documentation, translations, timezone data, bundled certificates and installer data are excluded.
'@ | Set-Content $notes -Encoding utf8NoBOM
& gh release view $tag --repo $env:GITHUB_REPOSITORY *> $null
if ($LASTEXITCODE -eq 0) {
    & gh release upload $tag $Archive $checksum --repo $env:GITHUB_REPOSITORY --clobber
    if ($LASTEXITCODE) { throw 'Release asset upload failed' }
    & gh release edit $tag --repo $env:GITHUB_REPOSITORY --title $tag --notes-file $notes --draft=false
} else {
    & gh release create $tag $Archive $checksum --repo $env:GITHUB_REPOSITORY --verify-tag --title $tag --notes-file $notes
}
if ($LASTEXITCODE) { throw 'Release publication failed' }
