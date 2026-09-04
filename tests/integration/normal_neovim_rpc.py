#!/usr/bin/env python3
import json
import os
import pathlib
import pty
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time


REPO = pathlib.Path(__file__).resolve().parents[2]
FIXTURES = REPO / "tests" / "fixtures" / "nucleo_cmake"
INTEGRATION = REPO / "tests" / "integration"


def skip(reason):
    print(f"SKIP normal Neovim RPC gate: {reason}")
    return 0


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


def prepare_project(base):
    root = base / "project with spaces"
    shutil.copytree(FIXTURES, root)
    tools = root / "tools"
    tools.mkdir()
    links = {
        "cmake": "fake_cmake.sh",
        "STM32_Programmer_CLI": "fake_programmer.sh",
        "arm-none-eabi-size": "fake_size.sh",
        "arm-none-eabi-objdump": "fake_objdump.sh",
        "stty": "fake_stty.sh",
        "cat": "fake_cat.sh",
    }
    for name, source in links.items():
        (tools / name).symlink_to(INTEGRATION / source)

    binary = root / "build" / "Debug"
    replies = binary / ".cmake" / "api" / "v1" / "reply"
    replies.mkdir(parents=True)
    (binary / "app.elf").write_bytes(b"fake-elf")
    write_json(
        replies / "index-rpc.json",
        {
            "objects": [
                {
                    "kind": "codemodel",
                    "version": {"major": 2},
                    "jsonFile": "codemodel-rpc.json",
                }
            ]
        },
    )
    write_json(
        replies / "codemodel-rpc.json",
        {
            "kind": "codemodel",
            "version": {"major": 2},
            "paths": {"source": str(root), "build": str(binary)},
            "configurations": [
                {
                    "name": "Debug",
                    "targets": [{"name": "app", "jsonFile": "target-rpc.json"}],
                }
            ],
        },
    )
    write_json(
        replies / "target-rpc.json",
        {
            "name": "app",
            "type": "EXECUTABLE",
            "paths": {"source": str(root), "build": str(binary)},
            "artifacts": [{"path": "app.elf"}],
        },
    )
    return root


def drain(fd, output):
    while True:
        try:
            chunk = os.read(fd, 8192)
        except OSError:
            return
        if not chunk:
            return
        output.extend(chunk)


def rpc(nvim, socket_path, expression, timeout=30):
    return subprocess.run(
        [nvim, "--server", str(socket_path), "--remote-expr", expression],
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def main():
    nvim = shutil.which("nvim")
    if not nvim:
        return skip("nvim is unavailable")
    help_result = subprocess.run(
        [nvim, "--help"], check=False, capture_output=True, text=True
    )
    if "--listen" not in help_result.stdout or "--server" not in help_result.stdout:
        return skip("this Neovim lacks RPC client/server support")

    try:
        terminal_master, terminal_slave = pty.openpty()
        uart_one_master, uart_one_slave = pty.openpty()
        uart_two_master, uart_two_slave = pty.openpty()
    except OSError as error:
        return skip(f"PTY allocation is unavailable: {error}")

    base = pathlib.Path(
        tempfile.mkdtemp(prefix="nvim-stm32-rpc-", dir="/tmp")
    ).resolve()
    process = None
    terminal_output = bytearray()
    try:
        root = prepare_project(base)
        fake_root = base / "fake-log"
        fake_root.mkdir()
        socket_path = base / "nvim.sock"
        environment = os.environ.copy()
        environment.update(
            {
                "TERM": "dumb",
                "NVIM_STM32_FAKE_ROOT": str(fake_root),
                "NVIM_STM32_FAKE_UART_CHUNK_1": "first ",
                "NVIM_STM32_FAKE_UART_CHUNK_2": "second\n",
                "NVIM_STM32_RPC_PROJECT": str(root),
                "NVIM_STM32_RPC_REPO": str(REPO),
                "NVIM_STM32_RPC_UART_ONE": os.ttyname(uart_one_slave),
                "NVIM_STM32_RPC_UART_TWO": os.ttyname(uart_two_slave),
                "NVIM_STM32_RPC_LUA": str(INTEGRATION / "normal_neovim_rpc.lua"),
                "PATH": f"{root / 'tools'}:{environment.get('PATH', '')}",
            }
        )
        process = subprocess.Popen(
            [
                nvim,
                "-u",
                str(INTEGRATION / "normal_init.lua"),
                "--listen",
                str(socket_path),
                str(root / "Core" / "Src" / "main.c"),
            ],
            cwd=root,
            env=environment,
            stdin=terminal_slave,
            stdout=terminal_slave,
            stderr=terminal_slave,
            start_new_session=True,
        )
        os.close(terminal_slave)
        terminal_slave = -1
        reader = threading.Thread(
            target=drain, args=(terminal_master, terminal_output), daemon=True
        )
        reader.start()

        deadline = time.monotonic() + 5
        while not socket_path.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        if not socket_path.exists():
            detail = terminal_output.decode("utf-8", errors="replace")
            raise RuntimeError(f"normal Neovim did not open its RPC socket\n{detail}")

        startup_deadline = time.monotonic() + 10
        while time.monotonic() < startup_deadline:
            ready = rpc(nvim, socket_path, "exists(':STM32Info')", timeout=3)
            if ready.returncode == 0 and ready.stdout.strip() == "2":
                break
            time.sleep(0.05)
        else:
            detail = terminal_output.decode("utf-8", errors="replace")
            raise RuntimeError(f"normal Neovim did not finish startup\n{detail}")

        result = rpc(
            nvim,
            socket_path,
            'luaeval("dofile(vim.env.NVIM_STM32_RPC_LUA).run()")',
        )
        if result.returncode != 0:
            raise RuntimeError(
                "RPC client failed: " + (result.stderr or result.stdout).strip()
            )
        report = json.loads(result.stdout.strip())
        if not report.get("ok"):
            detail = terminal_output.decode("utf-8", errors="replace")
            raise RuntimeError(
                report.get("error", "normal Neovim RPC gate failed")
                + (f"\nterminal output:\n{detail}" if detail else "")
            )
        print("normal Neovim RPC gate passed: UI, plan, build, analysis, flash, erase, and UART")
        return 0
    except (OSError, subprocess.SubprocessError, ValueError, RuntimeError) as error:
        print(f"normal Neovim RPC gate failed: {error}", file=sys.stderr)
        return 1
    finally:
        if process is not None and process.poll() is None:
            try:
                rpc(nvim, socket_path, "execute('qa!')", timeout=3)
            except (OSError, subprocess.SubprocessError):
                pass
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=3)
        for fd in (
            terminal_master,
            terminal_slave,
            uart_one_master,
            uart_one_slave,
            uart_two_master,
            uart_two_slave,
        ):
            if fd >= 0:
                try:
                    os.close(fd)
                except OSError:
                    pass
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
