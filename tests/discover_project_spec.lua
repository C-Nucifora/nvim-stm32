local root = require("nvim-stm32.discover.root")
local signals = require("nvim-stm32.discover.signals")
local project = require("nvim-stm32.discover.project")
local detect = require("nvim-stm32.detect")

local function fixture(rel)
  local here =
    vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
  return here .. "/fixtures/" .. rel
end

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

describe("nvim-stm32 project discovery", function()
  it("prefers the outer project over generated nested CMake", function()
    local found = assert(root.find(fixture("nucleo_cmake/cmake/stm32cubemx")))
    assert.equals(fixture("nucleo_cmake"), found)
  end)

  it("collects both images without flattening their cores", function()
    local resolved = assert(project.resolve(fixture("multi_image/CM4")))
    assert.equals(2, #resolved.images)
    assert.same(
      { "CM4", "CM7" },
      vim.tbl_map(function(image)
        return image.id
      end, resolved.images)
    )
  end)

  it("keeps image hints on every collected signal", function()
    local found = signals.collect(fixture("multi_image"))
    assert.equals(4, #found)
    assert.same(
      { "CM4", "CM7", "CM4", "CM7" },
      vim.tbl_map(function(signal)
        return signal.image_hint
      end, found)
    )
    assert.same(
      { "ioc", "ioc", "startup", "startup" },
      vim.tbl_map(function(signal)
        return signal.source
      end, found)
    )
  end)

  it("keeps the compatibility target on a single-image project", function()
    local target = assert(detect.target(fixture("nucleo_cmake/Core/Src")))
    assert.equals("STM32F429ZITx", target.mcu)
    assert.equals("cmake_presets", target.build_backend)
  end)

  it("selects the image nearest the compatibility target directory", function()
    local target = assert(detect.target(fixture("multi_image/CM7")))
    assert.equals("CM7", target.image_id)
    assert.equals("cortex-m7", target.core)
  end)

  it("prefers an .ioc marker over a weak CMakeLists marker in one directory", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. "/.git", "p")
    write(tmp .. "/firmware/CMakeLists.txt", { "cmake_minimum_required(VERSION 3.20)" })
    write(tmp .. "/firmware/app.ioc", { "Mcu.Name=STM32F429ZITx" })

    local found, adapter, marker = root.find(tmp .. "/firmware")
    assert.equals(tmp .. "/firmware", found)
    assert.is_nil(adapter)
    assert.equals(tmp .. "/firmware/app.ioc", marker)
    vim.fn.delete(tmp, "rf")
  end)

  it("keeps a nearer .ioc project ahead of an outer presets project", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. "/.git", "p")
    write(tmp .. "/CMakePresets.json", { "{}" })
    write(tmp .. "/firmware/app.ioc", { "Mcu.Name=STM32F429ZITx" })

    local found, adapter, marker = root.find(tmp .. "/firmware")
    assert.equals(tmp .. "/firmware", found)
    assert.is_nil(adapter)
    assert.equals(tmp .. "/firmware/app.ioc", marker)
    vim.fn.delete(tmp, "rf")
  end)

  it("collects CMake signals for every image and derives their hints", function()
    local tmp = vim.fn.tempname()
    write(tmp .. "/alpha/CMakeLists.txt", {
      "set(MCU STM32H747xx)",
      "add_executable(control_CM4 main.c)",
    })
    write(tmp .. "/beta/CMakeLists.txt", {
      "set(MCU STM32H747xx)",
      "add_executable(sensor main.c)",
      "add_compile_options(-mcpu=cortex-m7)",
    })

    local found = vim.tbl_filter(function(signal)
      return signal.source == "cmake"
    end, signals.collect(tmp))
    assert.equals(2, #found)
    assert.same(
      { "CM4", "CM7" },
      vim.tbl_map(function(signal)
        return signal.image_hint
      end, found)
    )
    vim.fn.delete(tmp, "rf")
  end)

  it("warns when an unhinted exact signal accompanies hinted images", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. "/.git", "p")
    write(tmp .. "/CMakePresets.json", { "{}" })
    write(tmp .. "/app.ioc", { "Mcu.Name=STM32H747XIHx" })
    write(tmp .. "/CM4/app.ioc", { "Mcu.Name=STM32H747XIHx" })
    write(tmp .. "/CM7/app.ioc", { "Mcu.Name=STM32H747XIHx" })

    local resolved = assert(project.resolve(tmp .. "/CM4"))
    assert.equals("ambiguous-images", resolved.provenance.warnings[1].code)
    vim.fn.delete(tmp, "rf")
  end)

  it("warns when exact unhinted signals collapse into one group", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. "/.git", "p")
    write(tmp .. "/CMakePresets.json", { "{}" })
    write(tmp .. "/first.ioc", { "Mcu.Name=STM32H747XIHx" })
    write(tmp .. "/second.ioc", { "Mcu.Name=STM32H747XIHx" })

    local resolved = assert(project.resolve(tmp))
    assert.equals("ambiguous-images", resolved.provenance.warnings[1].code)
    vim.fn.delete(tmp, "rf")
  end)

  it("collects every device macro from one CMake file", function()
    local tmp = vim.fn.tempname()
    write(tmp .. "/CMakeLists.txt", {
      "add_compile_definitions(STM32H747xx STM32H743xx)",
      "add_compile_options(-mcpu=cortex-m7)",
    })

    local found = vim.tbl_filter(function(signal)
      return signal.source == "cmake"
    end, signals.collect(tmp))
    assert.same(
      { "STM32H743xx", "STM32H747xx" },
      vim.tbl_map(function(signal)
        return signal.mcu
      end, found)
    )
    vim.fn.delete(tmp, "rf")
  end)

  it("does not absorb an unrelated .ioc sibling into a dual-image project", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. "/.git", "p")
    write(tmp .. "/CMakePresets.json", { "{}" })
    write(tmp .. "/CM4/app.ioc", { "Mcu.Name=STM32H747XIHx", "Mcu.UserName=chip_CM4" })
    write(tmp .. "/CM7/app.ioc", { "Mcu.Name=STM32H747XIHx", "Mcu.UserName=chip_CM7" })
    write(tmp .. "/unrelated/app.ioc", { "Mcu.Name=STM32F429ZITx" })

    local resolved = assert(project.resolve(tmp .. "/unrelated"))
    assert.equals(tmp .. "/unrelated", resolved.root)
    assert.equals("application", resolved.images[1].id)
    vim.fn.delete(tmp, "rf")
  end)

  it("keeps a CM4 CMake signal local when another file measures CM7", function()
    local tmp = vim.fn.tempname()
    write(tmp .. "/CM4/CMakeLists.txt", { "add_compile_definitions(STM32H747xx)" })
    write(tmp .. "/other/CMakeLists.txt", {
      "add_compile_definitions(STM32H747xx)",
      "add_compile_options(-mcpu=cortex-m7)",
    })

    local found = vim.tbl_filter(function(signal)
      return signal.source == "cmake" and signal.file:find("/CM4/", 1, true)
    end, signals.collect(tmp))
    assert.is_nil(found[1].core)
    assert.equals("CM4", found[1].image_hint)
    vim.fn.delete(tmp, "rf")
  end)

  it(
    "does not promote CM4 from nested CM7 evidence outside its sibling layout",
    function()
      local tmp = vim.fn.tempname()
      vim.fn.mkdir(tmp .. "/.git", "p")
      write(tmp .. "/CMakePresets.json", { "{}" })
      write(tmp .. "/CM4/app.ioc", { "Mcu.Name=STM32H747XIHx" })
      write(tmp .. "/examples/CM7/app.ioc", { "Mcu.Name=STM32H747XIHx" })

      local resolved = assert(project.resolve(tmp .. "/CM4"))
      assert.equals(tmp .. "/CM4", resolved.root)
      vim.fn.delete(tmp, "rf")
    end
  )

  it("does not inherit external CPU flags for a single CMake MCU match", function()
    local tmp = vim.fn.tempname()
    write(tmp .. "/CM4/CMakeLists.txt", { "add_compile_definitions(STM32H747xx)" })
    write(tmp .. "/toolchain.cmake", { "add_compile_options(-mcpu=cortex-m7)" })

    local found = vim.tbl_filter(function(signal)
      return signal.source == "cmake"
    end, signals.collect(tmp))
    assert.is_nil(found[1].core)
    assert.equals("CM4", found[1].image_hint)
    vim.fn.delete(tmp, "rf")
  end)

  it("keeps split CMake flags on a single-image compatibility target", function()
    local tmp = vim.fn.tempname()
    write(tmp .. "/CMakePresets.json", { "{}" })
    write(tmp .. "/cmake/stm32cubemx/CMakeLists.txt", {
      "add_compile_definitions(STM32F429xx)",
    })
    write(tmp .. "/cmake/toolchain.cmake", {
      "add_compile_options(-mcpu=cortex-m7 -mfpu=fpv5-sp-d16)",
    })

    local target = assert(detect.target(tmp))
    assert.equals("cortex-m7", target.core)
    assert.equals("fpv5-sp-d16", target.fpu)
    vim.fn.delete(tmp, "rf")
  end)

  it("does not aggregate CMake flags for ambiguous unhinted images", function()
    local tmp = vim.fn.tempname()
    write(tmp .. "/CMakePresets.json", { "{}" })
    write(tmp .. "/first.ioc", { "Mcu.Name=STM32F429ZITx" })
    write(tmp .. "/second.ioc", { "Mcu.Name=STM32F429ZITx" })
    write(
      tmp .. "/cmake/stm32cubemx/CMakeLists.txt",
      { "add_compile_definitions(STM32F429xx)" }
    )
    write(tmp .. "/cmake/toolchain.cmake", { "add_compile_options(-mcpu=cortex-m7)" })

    local target = assert(detect.target(tmp))
    assert.equals("cortex-m4", target.core)
    vim.fn.delete(tmp, "rf")
  end)

  it("keeps local startup core ahead of split CMake flags", function()
    local tmp = vim.fn.tempname()
    write(tmp .. "/CMakePresets.json", { "{}" })
    write(tmp .. "/app.ioc", { "Mcu.Name=STM32H747XIHx" })
    write(tmp .. "/startup_stm32h747xx.s", { ".cpu cortex-m4" })
    write(
      tmp .. "/cmake/stm32cubemx/CMakeLists.txt",
      { "add_compile_definitions(STM32H747xx)" }
    )
    write(tmp .. "/cmake/toolchain.cmake", { "add_compile_options(-mcpu=cortex-m7)" })

    local target = assert(detect.target(tmp))
    assert.equals("cortex-m4", target.core)
    vim.fn.delete(tmp, "rf")
  end)
end)
