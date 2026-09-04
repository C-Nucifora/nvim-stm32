#!/bin/sh
set -eu

root=${NVIM_STM32_FAKE_ROOT:?NVIM_STM32_FAKE_ROOT is required}
[ -d "$root" ] || exit 90

count_file="$root/stlink.count"
count=0
if [ -f "$count_file" ]; then
  IFS= read -r count < "$count_file"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

action=unknown
case "${0##*/}" in
  st-info) action=identify ;;
esac
for argument in "$@"; do
  case "$argument" in
    --probe) action=identify ;;
    write) action=program-verify ;;
    erase) action=erase ;;
    reset) action=reset ;;
  esac
done

printf 'stlink:%s\n' "$action" >> "$root/events"
argv_file=$(printf '%s/%03d-stlink-%s.argv' "$root" "$count" "$action")
{
  printf '%s\n' "$0"
  for argument in "$@"; do
    printf '%s\n' "$argument"
  done
} > "$argv_file"

case "$action" in
  identify)
    printf '%s\n' \
      'Found 1 stlink programmers' \
      '  version:    V3J15M7' \
      '  serial:     FAKEF429001' \
      '  chipid:     0x419' \
      '  dev-type:   STM32F42x_F43x'
    ;;
  program-verify)
    if [ "${NVIM_STM32_FAKE_FAIL:-}" = program ]; then
      printf '%s\n' 'st-flash write failed'
      exit 12
    fi
    printf '%s\n' 'Flash written and verified! jolly good!'
    ;;
  erase) printf '%s\n' 'Mass erasing' ;;
  reset) printf '%s\n' 'Resetting' ;;
  *)
    printf '%s\n' 'unsupported fake stlink arguments'
    exit 64
    ;;
esac
