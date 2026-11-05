#!/bin/bash
set -Eeuo pipefail
export PATH=/usr/bin:/bin LC_ALL=C
trap 'status=$?; printf "Packaging integration failed (exit %s), line %s: %s\n" "$status" "$LINENO" "$BASH_COMMAND" >&2; exit "$status"' ERR

check_runtime_dll() {
  local source=$1 destination=$2 required available missing
  objdump -f "$destination" | grep 'architecture: i386:x86-64' > /dev/null
  # Cygwin setup rebases DLLs independently in each installation. Compare their
  # exported ABI, not bytes (which include the image base and relocated data).
  required=$(objdump -p "$source" | awk '
    /^\[Ordinal\/Name Pointer\] Table/ { exports=1; next }
    exports && /^$/ { exports=0 }
    exports && /^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]/ {
      print $NF
    }' | sort -u)
  available=$(objdump -p "$destination" | awk '
    /^\[Ordinal\/Name Pointer\] Table/ { exports=1; next }
    exports && /^$/ { exports=0 }
    exports && /^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]/ {
      print $NF
    }' | sort -u)
  if [[ -z "$required" || -z "$available" ]]; then
    echo "Cannot inspect exported ABI: $source or $destination" >&2
    return 1
  fi
  missing=$(comm -23 <(printf '%s\n' "$required") <(printf '%s\n' "$available"))
  if [[ -n "$missing" ]]; then
    printf 'Incompatible runtime DLL %s; missing exports:\n%s\n' "$destination" "$missing" >&2
    return 1
  fi
}

[[ $(uname -s) == CYGWIN* ]] || { echo 'Requires Cygwin on Windows' >&2; exit 1; }
work=$(cygpath -au "$1")
runtime=$(cygpath -au "$2")
install -d "$runtime/usr/local/bin"

# Add commands here; no compiler is invoked during packaging.
for project in ripgrep fd; do
  source="$work/$project"
  if [[ $project == ripgrep ]]; then
    binary=rg
    version='ripgrep 15.2.0'
    revision='BurntSushi/ripgrep e89fff89ac9af12e8d4ce9d5fd07beb408ca730f'
    licenses=(COPYING LICENSE-MIT UNLICENSE Cargo.lock)
  else
    binary=fd
    version='fd-find 10.5.1'
    revision='sharkdp/fd 193d0df1d0ad455e44506953a2cd80428203ff35'
    licenses=(LICENSE-MIT LICENSE-APACHE Cargo.lock)
  fi
  executable="$source/target/x86_64-pc-cygwin/release/$binary.exe"
  objdump -p "$executable" | grep -i 'DLL Name: cygwin1[.]dll' > /dev/null
  objdump -p "$executable" | grep -E '[[:space:]]_dll_crt0[[:space:]]*$' > /dev/null
  install -d "$runtime/opt/$project/share"
  install -m 755 "$executable" "$runtime/usr/local/bin/$binary.exe"
  for license in "${licenses[@]}"; do
    install -m 644 "$source/$license" "$runtime/opt/$project/share/$license"
  done
  printf '%s\n' "$version" "$revision" > "$runtime/opt/$project/share/version.txt"
  if dependencies=$(cygcheck "$executable" 2>&1 | tr -d '\r'); then
    printf '%s\n' "$dependencies"
  else
    status=$?
    printf 'cygcheck failed (exit %s):\n%s\n' "$status" "$dependencies" >&2
    exit "$status"
  fi
  if [[ "$dependencies" == *'not found'* ]]; then
    echo 'Cannot package unresolved command dependencies' >&2
    exit 1
  fi
  while IFS= read -r dll; do
    dll=${dll#"${dll%%[![:space:]]*}"}
    [[ "$dll" == *.dll ]] || continue
    dll=$(cygpath -u "$dll")
    name=$(basename "$dll")
    [[ -f "/usr/bin/$name" ]] || continue
    if [[ -f "$runtime/bin/$name" ]]; then
      check_runtime_dll "$dll" "$runtime/bin/$name"
    else
      install -m 755 "$dll" "$runtime/bin/$name"
    fi
  done <<< "$dependencies"

done

# Cleanup and archiving run from PowerShell, outside this compiler Cygwin process.
# Do not execute ripgrep; ABI validation happens during the build.
