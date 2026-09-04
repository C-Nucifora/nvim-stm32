#!/bin/sh
set -eu

root=${NVIM_STM32_FAKE_ROOT:?NVIM_STM32_FAKE_ROOT is required}
[ -d "$root" ] || exit 90

action=configure
for argument in "$@"; do
  if [ "$argument" = --build ]; then
    action=build
  fi
done

printf 'cmake:%s\n' "$action" >> "$root/events"
printf '%s\n' "$0" "$@" > "$root/cmake-$action.argv"
sleep 0.1
printf 'fake cmake %s complete\n' "$action"
