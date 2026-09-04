local locks = require("nvim-stm32.locks")

describe("nvim-stm32.locks", function()
  it("acquires all requested locks atomically", function()
    local release_first = assert(locks.acquire("first", {
      { kind = "probe", id = "serial-1" },
    }))

    local release_second, err = locks.acquire("second", {
      { kind = "serial-device", id = "/dev/ttyACM0" },
      { kind = "probe", id = "serial-1" },
    })

    assert.is_nil(release_second)
    assert.equals("operation-lock-contended", err.code)
    assert.matches("probe", err.message, 1, true)
    assert.matches("serial-1", err.message, 1, true)
    assert.matches("first", err.message, 1, true)

    local release_serial = assert(locks.acquire("third", {
      { kind = "serial-device", id = "/dev/ttyACM0" },
    }))
    release_serial()
    release_first()
  end)

  it("distinguishes lock fields without delimiter-derived collisions", function()
    local release_first = assert(locks.acquire("first", {
      { kind = "probe:a", id = "b" },
    }))
    local release_second = assert(locks.acquire("second", {
      { kind = "probe", id = "a:b" },
    }))

    release_second()
    release_first()
  end)

  it("releases owned locks exactly once and permits reacquisition", function()
    local requested = {
      { kind = "probe", id = "serial-1" },
      { kind = "serial-device", id = "/dev/ttyACM0" },
    }
    local release = assert(locks.acquire("first", requested))

    release()
    release()

    local reacquired = assert(locks.acquire("second", requested))
    reacquired()
  end)

  it("does not let an old release closure clear a new owner's lock", function()
    local requested = { { kind = "probe", id = "serial-1" } }
    local release_first = assert(locks.acquire("same-owner", requested))
    release_first()
    local release_second = assert(locks.acquire("same-owner", requested))

    release_first()
    local release_third, err = locks.acquire("other-owner", requested)

    assert.is_nil(release_third)
    assert.equals("operation-lock-contended", err.code)
    release_second()
  end)
end)
