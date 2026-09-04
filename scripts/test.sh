#!/usr/bin/env bash
# Run the nvim-stm32 test suite headless with plenary-busted.
#
#   scripts/test.sh                        # the whole suite
#   scripts/test.sh tests/detect_spec.lua  # one file
#
# plenary is located via $PLENARY_PATH or the lazy.nvim data dir.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PLENARY_PATH="${PLENARY_PATH:-$HOME/.local/share/nvim/lazy/plenary.nvim}"

if [ "$#" -gt 0 ]; then
  nvim --headless --noplugin -u "$here/tests/minimal_init.lua" \
    -c "PlenaryBustedFile $1"
else
  nvim --headless --noplugin -u "$here/tests/minimal_init.lua" \
    -c "PlenaryBustedDirectory $here/tests { minimal_init = '$here/tests/minimal_init.lua', sequential = true }"
fi
