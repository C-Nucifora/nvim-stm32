--- Compatibility access to STM32 project discovery.
local project = require("nvim-stm32.discover.project")
local root = require("nvim-stm32.discover.root")
local signals = require("nvim-stm32.discover.signals")

local M = {}

M.markers = root.markers
M.start_dir = root.start_dir
M.markers_in = root.markers_in
M.root = root.find
M.read_ioc = signals.read_ioc
M.mcu_from_startup = signals.mcu_from_startup
M.mcu_from_linker = signals.mcu_from_linker
M.scan_cmake = signals.scan_cmake
M.signal_ioc = signals.signal_ioc
M.signal_startup = signals.signal_startup
M.signal_linker = signals.signal_linker
M.signal_cmake = signals.signal_cmake
M.mcu = signals.mcu

local function selected_image(images, dir)
  local from = vim.fs.normalize(dir or root.start_dir())
  local selected, longest = nil, -1
  for _, image in ipairs(images) do
    for _, signal in ipairs(image.target.signals) do
      local signal_dir = vim.fs.dirname(signal.file)
      if
        (from == signal_dir or vim.startswith(from, signal_dir .. "/"))
        and #signal_dir > longest
      then
        selected = image
        longest = #signal_dir
      end
    end
  end
  return selected or images[1]
end

function M.target(dir)
  local resolved, err = project.resolve(dir)
  if not resolved then
    return nil, err.message
  end

  local image = selected_image(resolved.images, dir)
  local target = vim.deepcopy(image.target)
  target.project = resolved
  target.image_id = image.id
  return target
end

return M
