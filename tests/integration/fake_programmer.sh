#!/bin/sh
set -eu

root=${NVIM_STM32_FAKE_ROOT:?NVIM_STM32_FAKE_ROOT is required}
[ -d "$root" ] || exit 90

count_file="$root/cubeprogrammer.count"
count=0
if [ -f "$count_file" ]; then
  IFS= read -r count < "$count_file"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

action=unknown
for argument in "$@"; do
  case "$argument" in
    -l) action=list ;;
    mode=HOTPLUG) action=identify ;;
    -w) action=program-verify ;;
    -e) action=erase ;;
    -rst) action=reset ;;
  esac
done

printf 'cubeprogrammer:%s\n' "$action" >> "$root/events"
argv_file=$(printf '%s/%03d-cubeprogrammer-%s.argv' "$root" "$count" "$action")
{
  printf '%s\n' "$0"
  for argument in "$@"; do
    printf '%s\n' "$argument"
  done
} > "$argv_file"

case "$action" in
  list)
    printf '%s\n' \
      '  Device Index           : 1' \
      '  ST-LINK SN             : FAKE-F429-001' \
      '  ST-LINK FW             : V3J15M7' \
      '  Board                  : NUCLEO-F429ZI'
    ;;
  identify)
    printf '%s\n' \
      '  ST-LINK SN             : FAKE-F429-001' \
      '  Voltage                : 3.30V' \
      '  Device ID              : 0x419' \
      '  Device name            : STM32F42xxx/F43xxx'
    ;;
  program-verify)
    case "${NVIM_STM32_FAKE_FAIL:-}" in
      write)
        printf '%s\n' 'write failed'
        exit 10
        ;;
      verify)
        printf '%s\n' 'verification failed'
        exit 11
        ;;
    esac
    printf '%s\n' 'Download verified successfully'
    ;;
  erase) printf '%s\n' 'Mass erase completed' ;;
  reset) printf '%s\n' 'Reset completed' ;;
  *)
    printf '%s\n' 'unsupported fake CubeProgrammer arguments'
    exit 64
    ;;
esac
