#!/bin/sh
set -eu

root=${NVIM_STM32_FAKE_ROOT:?NVIM_STM32_FAKE_ROOT is required}
[ -d "$root" ] || exit 90

printf '%s\n' 'uart:setup' >> "$root/events"
{
  printf '%s\n' "$0"
  for argument in "$@"; do
    printf '%s\n' "$argument"
  done
} > "$root/001-uart-setup.argv"

if [ "${NVIM_STM32_FAKE_FAIL:-}" = setup ]; then
  printf '%s\n' 'UART setup failed'
  exit 20
fi
printf '%s\n' 'UART configured'
