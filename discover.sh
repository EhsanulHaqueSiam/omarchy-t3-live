#!/bin/sh
# Prints an ssh host for each T3 linked environment, one per line, then "ok".
# Without the final "ok" (T3 not answering, no t3 command) the caller keeps
# what it knew, so a slow start never looks like "no linked machines".
#
# An environment whose address matches an alias in ~/.ssh/config (same name
# or same IP) is printed as that alias, reachable right now or not: the feed's
# own retries and its "out of date" state cover a machine that is away. An
# address with no alias is printed only if it answers key-based ssh and holds
# that very environment.
PATH="$HOME/.local/bin:$HOME/.t3/bin:$PATH"
command -v t3 >/dev/null || exit 1
envs=$(timeout 20 t3 environment list --json 2>/dev/null) || exit 1
printf '%s' "$envs" | jq -e 'type == "array"' >/dev/null 2>&1 || exit 1

aliases=$(awk 'tolower($1)=="host" { for (i=2;i<=NF;i++) if ($i !~ /[*?!]/) print $i }' "$HOME/.ssh/config" 2>/dev/null)

printf '%s' "$envs" | jq -r '.[] | .environmentId as $id | .urls[]? | select(test("t3coderelay") | not) | "\($id) \(.)"' |
  sed -E 's#^([^ ]+) [a-z]+://#\1 #; s#[:/][^ ]*$##' | sort -u | while read -r id addr; do
    case "$addr" in *[!A-Za-z0-9.-]*|"") continue ;; esac
    case "$id" in *[!0-9a-fA-F-]*|"") continue ;; esac
    ips=$(getent ahosts "$addr" 2>/dev/null | awk '{print $1}' | sort -u)
    found=""
    for alias in $aliases; do
      h=$(ssh -G "$alias" 2>/dev/null | awk '$1=="hostname"{print $2}')
      if [ "$h" = "$addr" ] || printf '%s\n' "$ips" | grep -qxF "$h"; then found=$alias; break; fi
    done
    if [ -n "$found" ]; then echo "$found"; continue; fi
    remote=$(timeout 8 ssh -o BatchMode=yes -o ConnectTimeout=5 "$addr" 'cat "${T3CODE_HOME:-$HOME/.t3}/userdata/environment-id"' </dev/null 2>/dev/null)
    [ "$remote" = "$id" ] && echo "$addr"
  done
echo ok
