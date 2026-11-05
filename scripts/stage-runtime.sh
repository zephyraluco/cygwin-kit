#!/bin/bash
# Build a portable runtime from an installed Cygwin tree, without modifying it.
# Also supports inspecting/staging an extracted release on Linux with binutils.
set -Eeuo pipefail
export LC_ALL=C
if [[ $(uname -s) == CYGWIN* ]]; then
  source_root=$(cygpath -au "${1:?Source runtime required}")
  stage=$(cygpath -au "${2:?Empty staging directory required}")
else
  source_root=$(realpath "${1:?Source runtime required}")
  stage=$(realpath -m "${2:?Empty staging directory required}")
fi
[[ "$stage/" != "$source_root/"* && "$source_root/" != "$stage/"* ]] || {
  echo 'Source and staging directories must not overlap' >&2; exit 1;
}
if [[ -e "$stage" && ( ! -d "$stage" || -n $(find "$stage" -mindepth 1 -print -quit) ) ]]; then
  echo "Refusing to overwrite nonempty staging path: $stage" >&2; exit 1
fi
mkdir -p "$stage"/{bin,etc,home,tmp,dev,proc,usr/bin,usr/local/bin,usr/sbin,usr/share/terminfo}
chmod 1777 "$stage/tmp"

# Resolve installation-relative symlinks against the source root, not the host.
resolve_source() {
  local path="$source_root/$1" target count=0
  while [[ -L "$path" ]]; do
    (( count += 1 ))
    (( count <= 20 )) || { echo "Symlink loop: $path" >&2; return 1; }
    target=$(readlink "$path")
    if [[ "$target" == /* ]]; then path="$source_root/$target"; else path="$(dirname "$path")/$target"; fi
  done
  path=$(realpath -m "$path")
  [[ "$path" == "$source_root/"* ]] || { echo "Source path escapes installation: $path" >&2; return 1; }
  printf '%s\n' "$path"
}
queue=()
declare -A copied=()
copy_program() {
  local relative=$1 origin
  [[ -z ${copied[$relative]+present} ]] || return 0
  origin=$(resolve_source "$relative")
  [[ -f "$origin" ]] || { echo "Required runtime file missing: $relative" >&2; return 1; }
  install -D -m 755 "$origin" "$stage/$relative"
  copied[$relative]=1
  queue+=("$relative")
}
for program in bash ssh sshpass scp sftp ssh-keygen ssh-agent ssh-add \
  ls cat cp mv rm mkdir ln chmod env dirname basename mktemp sed grep cygpath \
  head tail sort find wc xargs uniq cut tr gawk tar gzip sleep curl \
  cygwin-console-helper; do
  copy_program "bin/$program.exe"
done
ln "$stage/bin/bash.exe" "$stage/bin/sh.exe"
# Cygwin normally installs awk as a symlink to GNU awk. Ship portable EXE aliases.
ln "$stage/bin/gawk.exe" "$stage/bin/awk.exe"
for command in rg fd; do
  copy_program "usr/local/bin/$command.exe"
  strip --strip-debug "$stage/usr/local/bin/$command.exe"
  headers=$(objdump -p "$stage/usr/local/bin/$command.exe")
  grep -E 'Magic[[:space:]]+020b' <<< "$headers" > /dev/null
  grep -i 'DLL Name: cygwin1[.]dll' <<< "$headers" > /dev/null
  grep -E '[[:space:]]_dll_crt0[[:space:]]*$' <<< "$headers" > /dev/null
  objdump -f "$stage/usr/local/bin/$command.exe" | grep 'architecture: i386:x86-64' > /dev/null
done
for helper in ssh-keysign ssh-pkcs11-helper ssh-sk-helper; do
  copy_program "usr/sbin/$helper.exe"
done

# Follow PE imports recursively. Windows system DLLs are supplied by Windows;
# Cygwin DLLs must come from this installation and may never be silently skipped.
system_dlls='^(api-ms-win-.*|ext-ms-win-.*|advapi32|bcrypt|bcryptprimitives|cfgmgr32|crypt32|dnsapi|gdi32|hid|iphlpapi|kernel32|msvcrt|netapi32|normaliz|ntdll|ole32|oleaut32|psapi|rpcrt4|secur32|setupapi|shell32|shlwapi|user32|userenv|version|winmm|wintrust|winusb|ws2_32|wtsapi32|wldap32)[.]dll$|^winspool[.]drv$'
for (( index=0; index < ${#queue[@]}; index++ )); do
  image=${queue[index]}
  headers=$(objdump -p "$stage/$image")
  imports=$(awk '/DLL Name:/ {print $3}' <<< "$headers")
  [[ -n "$imports" ]] || { echo "No PE imports found: $image" >&2; exit 1; }
  while IFS= read -r dll; do
    dll=${dll,,}
    if [[ -f "$source_root/bin/$dll" ]]; then
      copy_program "bin/$dll"
    elif [[ ! "$dll" =~ $system_dlls ]]; then
      echo "Unresolved dependency: $image -> $dll" >&2
      exit 1
    fi
  done <<< "$imports"
done

for config in fstab nsswitch.conf; do
  origin=$(resolve_source "etc/$config")
  [[ ! -f "$origin" ]] || install -m 644 "$origin" "$stage/etc/$config"
done
# Minimal startup files must not call tools excluded from the whitelist.
cat > "$stage/etc/profile" <<'PROFILE'
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export TERMINFO=/usr/share/terminfo
export TZ="${TZ:-UTC0}"
export HOME="${HOME:-/home/${USER:-default}}"
mkdir -p "$HOME" 2>/dev/null || :
if [ -t 1 ]; then PS1='\u@\h:\w\$ '; fi
PROFILE
printf 'Host *\n    HashKnownHosts yes\n' > "$stage/etc/ssh_config"
for terminal in xterm xterm-256color cygwin dumb; do
  entry=$(find "$source_root/usr/share/terminfo" -name "$terminal" -print -quit)
  [[ -n "$entry" ]] || { echo "Missing terminal definition: $terminal" >&2; exit 1; }
  relative=${entry#"$source_root/"}
  origin=$(resolve_source "$relative")
  install -D -m 644 "$origin" "$stage/$relative"
done
for project in ripgrep fd; do
  mkdir -p "$stage/opt/$project/share"
  if [[ $project == ripgrep ]]; then
    metadata_files=(COPYING LICENSE-MIT UNLICENSE Cargo.lock version.txt)
  else
    metadata_files=(LICENSE-MIT LICENSE-APACHE Cargo.lock version.txt)
  fi
  for metadata in "${metadata_files[@]}"; do
    install -m 644 "$source_root/opt/$project/share/$metadata" "$stage/opt/$project/share/$metadata"
  done
done
printf '@echo off\r\n"%%~dp0bin\\bash.exe" --login -i\r\n' > "$stage/Cygwin.bat"

# No timezones, bundled certificates, installer state, or user data are copied.
for excluded in etc/ssl etc/pki etc/localtime etc/timezone usr/share/zoneinfo \
  usr/share/pki usr/share/ca-certificates var/lib/ca-certificates etc/setup; do
  [[ ! -e "$stage/$excluded" && ! -L "$stage/$excluded" ]] || {
    echo "Excluded data leaked into runtime: $excluded" >&2; exit 1;
  }
done
echo "Staged ${#queue[@]} executables/DLLs in $stage (no timezone or certificate data)"
