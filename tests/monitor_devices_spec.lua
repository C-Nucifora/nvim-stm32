local function load_devices()
  package.loaded["nvim-stm32.monitor.devices"] = nil
  return require("nvim-stm32.monitor.devices")
end

describe("nvim-stm32 UART device discovery", function()
  it(
    "uses the Darwin modem pattern and returns sorted unique character devices",
    function()
      local devices = load_devices()
      local patterns = {}
      local stats = {}
      local opened = 0

      local found = assert(devices.list({
        platform = "Darwin",
        glob = function(pattern)
          patterns[#patterns + 1] = pattern
          return {
            "/dev/cu.usbmodem20",
            "/dev/cu.usbmodem10",
            "/dev/cu.usbmodem20",
            "/dev/cu.usbmodem-regular",
          }
        end,
        stat = function(path)
          stats[#stats + 1] = path
          return { type = path:find("regular", 1, true) and "file" or "char" }
        end,
        open = function()
          opened = opened + 1
          error("discovery must not open a serial device")
        end,
      }))

      assert.same({ "/dev/cu.usbmodem*" }, patterns)
      assert.same({
        "/dev/cu.usbmodem-regular",
        "/dev/cu.usbmodem10",
        "/dev/cu.usbmodem20",
      }, stats)
      assert.same({ "/dev/cu.usbmodem10", "/dev/cu.usbmodem20" }, found)
      assert.equals(0, opened)
    end
  )

  it("uses the Linux ACM pattern and stats each unique candidate once", function()
    local devices = load_devices()
    local patterns = {}
    local stat_count = {}

    local found = assert(devices.list({
      platform = "Linux",
      glob = function(pattern)
        patterns[#patterns + 1] = pattern
        return { "/dev/ttyACM2", "/dev/ttyACM0", "/dev/ttyACM2" }
      end,
      stat = function(path)
        stat_count[path] = (stat_count[path] or 0) + 1
        return { type = "char" }
      end,
    }))

    assert.same({ "/dev/ttyACM*" }, patterns)
    assert.same({ "/dev/ttyACM0", "/dev/ttyACM2" }, found)
    assert.same({ ["/dev/ttyACM0"] = 1, ["/dev/ttyACM2"] = 1 }, stat_count)
  end)

  it("rejects unsupported platforms without globbing or statting", function()
    local devices = load_devices()
    local calls = 0

    local found, err = devices.list({
      platform = "Windows_NT",
      glob = function()
        calls = calls + 1
      end,
      stat = function()
        calls = calls + 1
      end,
    })

    assert.is_nil(found)
    assert.equals("monitor-platform-unsupported", err.code)
    assert.equals(0, calls)
  end)

  it("requires an existing character device by default", function()
    local devices = load_devices()

    local valid = assert(devices.validate("/dev/ttyACM0", {
      stat = function()
        return { type = "char" }
      end,
    }))
    local missing, missing_err = devices.validate("/dev/ttyACM1", {
      stat = function()
        return nil
      end,
    })
    local regular, regular_err = devices.validate("/tmp/serial.log", {
      stat = function()
        return { type = "file" }
      end,
    })

    assert.equals("/dev/ttyACM0", valid)
    assert.is_nil(missing)
    assert.equals("monitor-device-not-found", missing_err.code)
    assert.is_nil(regular)
    assert.equals("monitor-device-not-found", regular_err.code)
  end)
end)
