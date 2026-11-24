#!/bin/sh
# Opens a T3 Code thread: sh open.sh <environmentId> <threadId>
# The desktop app takes t3code:// links; without it, the thread opens in this
# machine's T3 web UI.
case "$1/$2" in */*/*|*[!0-9a-zA-Z/-]*|/*|*/) exit 1 ;; esac
xdg-open "t3code://threads/$1/$2" 2>/dev/null && exit 0
origin=$(jq -r '.origin // empty' "${T3CODE_HOME:-$HOME/.t3}/userdata/server-runtime.json" 2>/dev/null)
[ -n "$origin" ] && exec xdg-open "$origin/$1/$2"
exit 1
