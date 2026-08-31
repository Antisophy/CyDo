#!/bin/sh

is_title=0
for arg in "$@"; do
  case "$arg" in
    *"Generate a concise title"*)
      is_title=1
      ;;
  esac
done

real_claude=$(command -v claude)
if [ "$is_title" -eq 0 ]; then
  exec "$real_claude" "$@"
fi

"$real_claude" "$@" &
claude_pid=$!

terminate_title() {
  trap - TERM
  kill -TERM "$claude_pid" 2>/dev/null || true
  kill -TERM "$$"
}

trap terminate_title TERM
wait "$claude_pid"
status=$?
trap - TERM
exit "$status"
