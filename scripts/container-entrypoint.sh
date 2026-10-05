#!/bin/sh
set -eu

current_nofile=$(ulimit -n)
case "$current_nofile" in
  unlimited)
    ulimit -n 65536 || {
      echo "unable to cap unlimited open-file limit" >&2
      exit 70
    }
    ;;
  *[!0-9]*|"")
    echo "unable to read open-file limit: $current_nofile" >&2
    exit 70
    ;;
  *)
    if [ "$current_nofile" -gt 65536 ]; then
      ulimit -n 65536 || {
        echo "unable to cap open-file limit from $current_nofile" >&2
        exit 70
      }
    fi
    ;;
esac

exec "$@"
