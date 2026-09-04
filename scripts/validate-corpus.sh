#!/bin/sh
set -eu

usage="usage: scripts/validate-corpus.sh CORPUS_ROOT [--build]"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "$usage" >&2
  exit 2
fi
if [ "$#" -eq 2 ] && [ "$2" != "--build" ]; then
  echo "$usage" >&2
  exit 2
fi
if [ ! -d "$1" ]; then
  echo "corpus root is not a directory: $1" >&2
  exit 2
fi

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
exec nvim --headless --noplugin -u "$repo_dir/tests/minimal_init.lua" \
  -l "$repo_dir/scripts/validate_corpus.lua" -- "$@"
