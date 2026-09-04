#!/bin/sh
set -eu

root=${NVIM_STM32_FAKE_ROOT:?NVIM_STM32_FAKE_ROOT is required}
[ -d "$root" ] || exit 90

{
  printf '%s\n' "$0"
  for argument in "$@"; do
    printf '%s\n' "$argument"
  done
} > "$root/elf-inspection.argv"

printf '%s\n' \
  'fake.elf: file format elf32-littlearm' \
  'Sections:' \
  'Idx Name          Size      VMA       LMA       File off  Algn' \
  '  0 .text         00000008  08000000  08000000  00001000  2**2' \
  '                  CONTENTS, ALLOC, LOAD, READONLY, CODE' \
  '  1 .bss          00000004  20000000  20000000  00002000  2**2' \
  '                  ALLOC'
