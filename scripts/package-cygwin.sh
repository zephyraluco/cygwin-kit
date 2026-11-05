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
rg_source="$work/ripgrep"
rg_binary="$rg_source/target/x86_64-pc-cygwin/release/rg.exe"
objdump -p "$rg_binary" | grep -i 'DLL Name: cygwin1[.]dll' > /dev/null
objdump -p "$rg_binary" | grep -E '[[:space:]]_dll_crt0[[:space:]]*$' > /dev/null
install -d "$runtime/opt/ripgrep/share"
install -m 755 "$rg_binary" "$runtime/usr/local/bin/rg.exe"
for license in COPYING LICENSE-MIT UNLICENSE Cargo.lock; do
  install -m 644 "$rg_source/$license" "$runtime/opt/ripgrep/share/$license"
done
printf '%s\n' 'ripgrep 15.1.0' 'BurntSushi/ripgrep af60c2de9d85e7f3d81c78601669468cf02dabab' > "$runtime/opt/ripgrep/share/version.txt"
if dependencies=$(cygcheck "$rg_binary" 2>&1 | tr -d '\r'); then
  printf '%s\n' "$dependencies"
else
  status=$?
  printf 'cygcheck failed (exit %s):\n%s\n' "$status" "$dependencies" >&2
  exit "$status"
fi
if [[ "$dependencies" == *'not found'* ]]; then
  echo 'Cannot package unresolved ripgrep dependencies' >&2
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

# Cleanup and archiving run from PowerShell, outside this compiler Cygwin process.
# Do not execute ripgrep; ABI validation happens during the build.
