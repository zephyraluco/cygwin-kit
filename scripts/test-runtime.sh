#!/bin/bash
# Run only inside the staged Cygwin root, from the PowerShell host.
set -Eeuo pipefail
trap 'status=$?; printf "Runtime validation failed (exit %s), line %s: %s\n" "$status" "$LINENO" "$BASH_COMMAND" >&2; exit "$status"' ERR
export PATH=/usr/local/bin:/usr/bin:/bin LC_ALL=C.UTF-8
[[ "$OSTYPE" == cygwin ]]
# Windows runner paths may use RUNNER~1 while Cygwin / uses runneradmin.
# Resolve both spellings to long paths before comparing on a case-insensitive OS.
actual_root=$(cygpath -aml /)
expected_root=$(cygpath -aml "${1:?Expected staging root required}")
actual_root=${actual_root%/}
expected_root=${expected_root%/}
if [[ "${actual_root,,}" != "${expected_root,,}" ]]; then
  printf 'Wrong runtime root: actual=%s expected=%s\n' "$actual_root" "$expected_root" >&2
  exit 1
fi
for program in bash sh ssh sshpass scp sftp ssh-keygen ssh-agent ssh-add \
  ls cat cp mv rm mkdir ln chmod env dirname basename mktemp sed grep cygpath rg \
  head tail sort find wc xargs uniq cut tr awk tar gzip; do
  command -v "$program" > /dev/null || { echo "Missing runtime command: $program" >&2; exit 1; }
done
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
printf 'runtime-ok\n' > "$scratch/input"
cp "$scratch/input" "$scratch/copy"
test "$(cat "$scratch/copy")" = runtime-ok
test "$(sed s/runtime/shell/ "$scratch/copy" | grep shell-ok)" = shell-ok
test "$(sh -c 'printf sh-ok')" = sh-ok
printf 'b,2\na,1\nb,2\n' > "$scratch/rows"
test "$(head -n 1 "$scratch/rows")" = b,2
test "$(tail -n 1 "$scratch/rows")" = b,2
test "$(sort "$scratch/rows" | uniq | cut -d, -f1 | tr '\n' ':')" = a:b:
test "$(wc -l < "$scratch/rows" | tr -d '[:space:]')" = 3
test "$(find "$scratch" -name rows -type f)" = "$scratch/rows"
test "$(printf '%s\n' "$scratch/rows" | xargs -I '{}' cat '{}')" = "$(cat "$scratch/rows")"
test "$(awk -F, '{total += $2} END {print total}' "$scratch/rows")" = 5
tar -czf "$scratch/rows.tar.gz" -C "$scratch" rows
mkdir "$scratch/extract"
tar -xzf "$scratch/rows.tar.gz" -C "$scratch/extract"
test "$(cat "$scratch/extract/rows")" = "$(cat "$scratch/rows")"
ssh -V
sshpass -V
ssh -G -F /etc/ssh_config example.invalid > /dev/null
ssh-keygen -q -t ed25519 -N '' -f "$scratch/key"
ssh-keygen -lf "$scratch/key.pub"
for excluded in /etc/ssl /etc/pki /etc/localtime /etc/timezone /usr/share/zoneinfo \
  /usr/share/pki /usr/share/ca-certificates /var/lib/ca-certificates /etc/setup; do
  [[ ! -e "$excluded" && ! -L "$excluded" ]]
done
# rg is deliberately not executed; PE/ABI checks run in the build/staging scripts.
echo 'Minimal runtime shell, file tools, SSH and data exclusions passed'
