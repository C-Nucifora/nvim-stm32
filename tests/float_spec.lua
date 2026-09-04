local float = require("nvim-stm32.ui.float")

local target = { mcu = "STM32F429ZITx", family = "STM32F4" }

local function config(delay)
  return {
    float = {
      border = "rounded",
      close_on_success_ms = delay or 0,
    },
  }
end

describe("nvim-stm32.ui.float", function()
  local loaded_snacks
  local presenters

  before_each(function()
    loaded_snacks = package.loaded.snacks
    package.loaded.snacks = false
    presenters = {}
  end)

  after_each(function()
    for _, presenter in ipairs(presenters) do
      presenter:close()
      if vim.api.nvim_buf_is_valid(presenter.buf) then
        vim.api.nvim_buf_delete(presenter.buf, { force = true })
      end
    end
    package.loaded.snacks = loaded_snacks
  end)

  it("opens a titled fallback window and joins partial output chunks", function()
    local presenter = float.open(target, config())
    presenters[#presenters + 1] = presenter

    assert.is_true(vim.api.nvim_buf_is_valid(presenter.buf))
    assert.is_true(vim.api.nvim_win_is_valid(presenter.win))
    assert.matches(
      "STM32F429ZITx",
      vim.inspect(vim.api.nvim_win_get_config(presenter.win).title),
      1,
      true
    )

    presenter:append("configuring\nbuil")
    presenter:append("ding\n")
    assert.same(
      { "configuring", "building" },
      vim.api.nvim_buf_get_lines(presenter.buf, 0, -1, false)
    )
  end)

  it("uses a caller-supplied operation title", function()
    local title = " nvim-stm32 reset: STM32F429ZITx "
    local presenter = float.open(target, config(), { title = title })
    presenters[#presenters + 1] = presenter

    assert.matches(
      "nvim-stm32 reset: STM32F429ZITx",
      vim.inspect(vim.api.nvim_win_get_config(presenter.win).title),
      1,
      true
    )
  end)

  it("keeps failed output open and flushes its last partial line", function()
    local presenter = float.open(target, config())
    presenters[#presenters + 1] = presenter
    presenter:append("compiler error")

    presenter:finish(false)

    assert.is_true(vim.api.nvim_win_is_valid(presenter.win))
    assert.same(
      { "compiler error" },
      vim.api.nvim_buf_get_lines(presenter.buf, 0, -1, false)
    )
  end)

  it("closes successful output after the configured delay", function()
    local presenter = float.open(target, config(0))
    presenters[#presenters + 1] = presenter

    presenter:finish(true)

    assert.is_true(vim.wait(100, function()
      return not vim.api.nvim_win_is_valid(presenter.win)
    end))
  end)

  it("keeps successful output open when auto-close is disabled", function()
    local presenter = float.open(target, config(0), { close_on_success = false })
    presenters[#presenters + 1] = presenter

    presenter:finish(true)
    vim.wait(25, function()
      return false
    end)

    assert.is_true(vim.api.nvim_win_is_valid(presenter.win))
  end)

  it("calls on_close once for a user-closed native window", function()
    local closes = 0
    local presenter = float.open(target, config(), function()
      closes = closes + 1
    end)
    presenters[#presenters + 1] = presenter

    vim.api.nvim_win_close(presenter.win, true)

    assert.equals(1, closes)
  end)

  it("does not call on_close when success closes the native window", function()
    local closes = 0
    local presenter = float.open(target, config(0), function()
      closes = closes + 1
    end)
    presenters[#presenters + 1] = presenter

    presenter:finish(true)

    assert.is_true(vim.wait(100, function()
      return not vim.api.nvim_win_is_valid(presenter.win)
    end))
    assert.equals(0, closes)
  end)

  it("uses snacks.win when it is available", function()
    local recorded
    local snack_window
    package.loaded.snacks = {
      win = function(opts)
        recorded = opts
        snack_window = {
          show = function(self)
            self.win = vim.api.nvim_open_win(opts.buf, false, {
              relative = "editor",
              row = 0,
              col = 0,
              width = 20,
              height = 5,
              style = "minimal",
              border = opts.border,
              title = opts.title,
            })
            return self
          end,
          close = function(self)
            if self.win and vim.api.nvim_win_is_valid(self.win) then
              vim.api.nvim_win_close(self.win, true)
            end
          end,
        }
        return snack_window
      end,
    }

    local presenter = float.open(target, config())
    presenters[#presenters + 1] = presenter

    assert.equals(presenter.buf, recorded.buf)
    assert.equals(snack_window, presenter.snacks)
    assert.equals(snack_window.win, presenter.win)
    assert.is_true(vim.api.nvim_win_is_valid(presenter.win))
  end)

  it("calls on_close once for a user-closed snacks window", function()
    local snack_window
    local closes = 0
    package.loaded.snacks = {
      win = function(opts)
        snack_window = {
          show = function(self)
            self.win = vim.api.nvim_open_win(opts.buf, false, {
              relative = "editor",
              row = 0,
              col = 0,
              width = 20,
              height = 5,
              style = "minimal",
            })
            return self
          end,
          close = function(self)
            vim.api.nvim_win_close(self.win, true)
          end,
        }
        return snack_window
      end,
    }

    local presenter = float.open(target, config(), function()
      closes = closes + 1
    end)
    presenters[#presenters + 1] = presenter
    vim.api.nvim_win_close(presenter.win, true)

    assert.equals(1, closes)
  end)
end)
