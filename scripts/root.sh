#!/usr/bin/env bash
set -euo pipefail
case ${DRY_RUN:-0} in
  1) exec bash "$@" ;;
  0) exec sudo --preserve-env=SSH_CONNECTION bash "$@" ;;
  *)
    printf 'DRY_RUN must be 0 or 1.\n' >&2
    exit 1
    ;;
esac
