#!/bin/sh
set -eu

usage='usage: scripts/validate-f429-software.sh CORPUS_ROOT'

if [ "$#" -ne 1 ]; then
  echo "$usage" >&2
  exit 2
fi
if [ ! -d "$1" ]; then
  echo "corpus root is not a directory: $1" >&2
  exit 2
fi

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
corpus_root=$(CDPATH='' cd -- "$1" && pwd)
discovery_log=$(mktemp "${TMPDIR:-/tmp}/nvim-stm32-discovery.XXXXXX")
build_log=$(mktemp "${TMPDIR:-/tmp}/nvim-stm32-build.XXXXXX")
# shellcheck disable=SC2329
cleanup_exit() {
  cleanup_code=$?
  trap - EXIT HUP INT TERM
  rm -f "$discovery_log" "$build_log"
  exit "$cleanup_code"
}
# shellcheck disable=SC2329
cleanup_signal() {
  cleanup_code=$1
  trap - EXIT HUP INT TERM
  rm -f "$discovery_log" "$build_log"
  exit "$cleanup_code"
}
trap cleanup_exit EXIT
trap 'cleanup_signal 129' HUP
trap 'cleanup_signal 130' INT
trap 'cleanup_signal 143' TERM

cd "$repo_dir"
scripts/test.sh
stylua --check lua/ tests/
tests/integration/normal-neovim-rpc.sh

discovery_status=0
scripts/validate-corpus.sh "$corpus_root" > "$discovery_log" 2>&1 \
  || discovery_status=$?
cat "$discovery_log"
printf '\n'
if [ "$discovery_status" -ne 0 ]; then
  echo "F429 discovery gate failed with status $discovery_status." >&2
  exit 1
fi
if ! grep -Fxq '13/13 projects passed' "$discovery_log"; then
  echo 'F429 discovery gate expected exactly 13/13 projects' >&2
  exit 1
fi

if scripts/validate-corpus.sh "$corpus_root" --build > "$build_log" 2>&1; then
  cat "$build_log"
  printf '\n'
  if ! grep -Fxq '13/13 projects passed' "$build_log"; then
    echo 'F429 build gate expected exactly 13/13 projects' >&2
    exit 1
  fi
  echo 'F429 software acceptance passed: 13/13 projects built with fresh application ELFs.'
  exit 0
fi

cat "$build_log"
printf '\n'
failure_count=$(grep -c '^FAIL ' "$build_log" || true)
known_count=$(grep -Fc "FAIL $corpus_root/Stage0/GPIO_IOToggle:" "$build_log" || true)
if [ "$failure_count" -eq 1 ] \
  && [ "$known_count" -eq 1 ] \
  && grep -Fxq '12/13 projects passed' "$build_log" \
  && grep -Fq -- "unrecognized command-line option '-fcyclomatic-complexity'" "$build_log"
then
  echo "KNOWN EXPECTED FAILURE $corpus_root/Stage0/GPIO_IOToggle: the installed ARM GCC rejects -fcyclomatic-complexity."
  echo 'F429 software acceptance passed with the recorded compiler-flag exception: 12/13 projects built with fresh application ELFs.'
  exit 0
fi

echo 'F429 software acceptance failed outside the recorded Stage0/GPIO_IOToggle compiler-flag exception.' >&2
exit 1
