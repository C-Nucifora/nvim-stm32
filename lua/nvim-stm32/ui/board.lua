local M = {}

function M.lines(board)
  local ids = vim.tbl_map(function(id)
    return string.format("0x%03X", id)
  end, board.expected_device_ids or {})
  local match = {
    match = "Device ID matches the project. Shared IDs cannot confirm the exact MCU or board.",
    mismatch = "Device ID does not match the project. Check the target before flashing.",
    unknown = "Compatibility unknown. The project has no known device IDs.",
  }
  return {
    "Connected board",
    "Backend: " .. board.backend,
    "Probe serial: " .. board.serial,
    "Probe firmware: " .. (board.firmware or "not reported"),
    string.format("Device ID: 0x%03X", board.device_id),
    "Device name: " .. (board.device_name or "not reported"),
    "Target voltage: " .. (board.voltage_mv and string.format(
      "%.3f V",
      board.voltage_mv / 1000
    ) or "not reported"),
    "Project target: " .. (board.expected_mcu or "unknown"),
    "Expected device IDs: " .. (#ids > 0 and table.concat(ids, ", ") or "unknown"),
    match[board.target_match],
    "Connection checked. Flash readiness also depends on the build, memory layout, and hardware wiring.",
  }
end

return M
