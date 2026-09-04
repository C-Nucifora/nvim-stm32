local process = require("nvim-stm32.process")

describe("nvim-stm32.process.run", function()
  local original_system
  local calls
  local exit_codes

  before_each(function()
    original_system = process.system
    calls = {}
    exit_codes = { 0, 0 }

    process.system = function(cmd, opts, callback)
      calls[#calls + 1] = { cmd = cmd, opts = opts }
      local index = #calls
      opts.stdout(nil, "stdout " .. index .. "\n")
      opts.stderr(nil, "stderr " .. index .. "\n")
      callback({ code = exit_codes[index], signal = 0 })
      return { kill = function() end }
    end
  end)

  after_each(function()
    process.system = original_system
  end)

  it("runs commands in order with the requested cwd and environment", function()
    local output = {}
    local done
    local commands = {
      { "cmake", "--preset", "Debug" },
      { "cmake", "--build", "build/Debug" },
    }

    process.run(commands, {
      cwd = "/work/fw",
      env = { PATH = "/toolchain:/usr/bin" },
      on_output = function(chunk)
        output[#output + 1] = chunk
      end,
    }, function(result)
      done = result
    end)

    assert.is_true(vim.wait(100, function()
      return done ~= nil
    end))
    assert.same(commands[1], calls[1].cmd)
    assert.same(commands[2], calls[2].cmd)
    assert.equals("/work/fw", calls[1].opts.cwd)
    assert.equals("/toolchain:/usr/bin", calls[1].opts.env.PATH)
    assert.same({ "stdout 1\n", "stderr 1\n", "stdout 2\n", "stderr 2\n" }, output)
    assert.same({
      code = 0,
      signal = 0,
      output = "stdout 1\nstderr 1\nstdout 2\nstderr 2\n",
      command = commands[2],
    }, done)
  end)

  it("stops after the first failed command", function()
    exit_codes[1] = 1
    local done
    local commands = {
      { "cmake", "--preset", "Debug" },
      { "cmake", "--build", "build/Debug" },
    }

    process.run(commands, { cwd = "/work/fw", env = {} }, function(result)
      done = result
    end)

    assert.is_true(vim.wait(100, function()
      return done ~= nil
    end))
    assert.equals(1, #calls)
    assert.same(commands[1], done.command)
    assert.equals(1, done.code)
    assert.equals("stdout 1\nstderr 1\n", done.output)
  end)
end)
