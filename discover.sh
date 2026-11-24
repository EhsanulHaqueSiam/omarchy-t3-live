#!/bin/sh
# Prints an ssh host for each T3 linked environment this machine can reach
# over key-based ssh, one per line. It matches each environment's address to
# an ssh alias that points at the same machine, else tries the address itself.
command -v t3 >/dev/null || exit 0
envs=$(timeout 20 t3 environment list --json 2>/dev/null) || exit 0
printf '%s' "$envs" | jq -r '.[]? | .urls[]? | select(test("t3coderelay") | not)' 2>/dev/null |
  sed -E 's#^[a-z]+://##; s#[:/].*$##' | sort -u | while read -r addr; do
    case "$addr" in *[!A-Za-z0-9.-]*|"") continue ;; esac
    ips=$(getent ahosts "$addr" 2>/dev/null | awk '{print $1}' | sort -u)
    found=""
    for alias in $(awk 'tolower($1)=="host" { for (i=2;i<=NF;i++) if ($i !~ /[*?!]/) print $i }' "$HOME/.ssh/config" 2>/dev/null); do
      h=$(ssh -G "$alias" 2>/dev/null | awk '$1=="hostname"{print $2}')
      if [ "$h" = "$addr" ] || printf '%s\n' "$ips" | grep -qxF "$h"; then found=$alias; break; fi
    done
    [ -n "$found" ] || found=$addr
    # Only machines that answer key-based ssh and have T3's data.
    timeout 8 ssh -o BatchMode=yes -o ConnectTimeout=5 "$found" 'test -f "${T3CODE_HOME:-$HOME/.t3}/userdata/environment-id"' </dev/null 2>/dev/null && echo "$found"
  done
