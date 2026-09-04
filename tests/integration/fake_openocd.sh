#!/bin/sh
set -eu

root=${NVIM_STM32_FAKE_ROOT:?NVIM_STM32_FAKE_ROOT is required}
[ -d "$root" ] || exit 90

count_file="$root/openocd.count"
count=0
if [ -f "$count_file" ]; then
  IFS= read -r count < "$count_file"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

action=unknown
for argument in "$@"; do
  case "$argument" in
    *mdw*) action=identify ;;
    program\ *) action=program-verify ;;
    *erase_sector*) action=erase ;;
    *reset\ run*) action=reset ;;
  esac
done

printf 'openocd:%s\n' "$action" >> "$root/events"
argv_file=$(printf '%s/%03d-openocd-%s.argv' "$root" "$count" "$action")
{
  printf '%s\n' "$0"
  for argument in "$@"; do
    printf '%s\n' "$argument"
  done
} > "$argv_file"

case "$action" in
  identify) printf '%s\n' '0xe0042000: 10016419' ;;
  program-verify) printf '%s\n' 'verified 1024 bytes' ;;
  erase) printf '%s\n' 'erased sectors 0 through last' ;;
  reset) printf '%s\n' 'target running' ;;
  *)
    printf '%s\n' 'unsupported fake OpenOCD arguments'
    exit 64
    ;;
esac
