#!/bin/sh
set -eu

root=${NVIM_STM32_FAKE_ROOT:?NVIM_STM32_FAKE_ROOT is required}
[ -d "$root" ] || exit 90

artifact=
for argument in "$@"; do
  artifact=$argument
done
printf '%s\n' "$0" "$@" > "$root/size.argv"
printf '%s\n' \
  '   text    data     bss     dec     hex filename' \
  "      8       0       4      12       c $artifact"
