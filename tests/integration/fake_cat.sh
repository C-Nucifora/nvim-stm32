#!/bin/sh
set -eu

root=${NVIM_STM32_FAKE_ROOT:?NVIM_STM32_FAKE_ROOT is required}
[ -d "$root" ] || exit 90

printf '%s\n' 'uart:stream' >> "$root/events"
{
  printf '%s\n' "$0"
  for argument in "$@"; do
    printf '%s\n' "$argument"
  done
} > "$root/002-uart-stream.argv"

printf '%s' "${NVIM_STM32_FAKE_UART_CHUNK_1:-first }"
sleep 0.05
printf '%s' "${NVIM_STM32_FAKE_UART_CHUNK_2:-second\n}"

trap 'exit 0' TERM INT
while :; do
  sleep 1
done
