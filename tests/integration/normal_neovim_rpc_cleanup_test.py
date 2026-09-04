#!/usr/bin/env python3
import os
import pathlib
import select
import signal
import subprocess
import sys
import tempfile
import time
from unittest import mock

import normal_neovim_rpc


def wait_for_unreaped_exit(process, timeout=5):
    deadline = time.monotonic() + timeout
    flags = os.WEXITED | os.WNOHANG | os.WNOWAIT
    while time.monotonic() < deadline:
        status = os.waitid(os.P_PID, process.pid, flags)
        if status is not None and status.si_pid == process.pid:
            return
        time.sleep(0.01)
    raise AssertionError("leader did not exit without being reaped")


def check_finalize_order():
    events = []

    class Process:
        pid = 424242

        def poll(self):
            events.append("poll")
            raise AssertionError("finalization polled before process-group cleanup")

        def wait(self, timeout):
            events.append("wait")
            return 0

    def exited_without_reaping(_process):
        events.append("status")
        return True

    def killpg(group_id, requested_signal):
        if group_id != Process.pid:
            raise AssertionError("finalization signalled the wrong process group")
        events.append(("killpg", requested_signal))

    with mock.patch.object(
        normal_neovim_rpc,
        "process_exited_without_reaping",
        side_effect=exited_without_reaping,
    ), mock.patch.object(normal_neovim_rpc.os, "killpg", side_effect=killpg):
        normal_neovim_rpc.finalize_owned_process(None, None, Process(), Process.pid, 0)

    expected = [
        "status",
        ("killpg", signal.SIGTERM),
        ("killpg", signal.SIGKILL),
        "wait",
    ]
    if events != expected:
        raise AssertionError(f"unexpected finalization order: {events!r}")


def main():
    check_finalize_order()
    with tempfile.TemporaryDirectory(prefix="nvim-stm32-cleanup-") as directory:
        pid_file = pathlib.Path(directory) / "descendant.pid"
        leader = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import pathlib, subprocess, sys; "
                "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)']); "
                "pathlib.Path(sys.argv[1]).write_text(str(child.pid), encoding='utf-8')",
                str(pid_file),
            ],
            start_new_session=True,
            stdout=subprocess.PIPE,
        )
        group_id = leader.pid
        try:
            deadline = time.monotonic() + 5
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            if not pid_file.exists():
                raise AssertionError("leader did not record its descendant")
            descendant = int(pid_file.read_text(encoding="utf-8"))
            if os.getpgid(descendant) != group_id:
                raise AssertionError("descendant did not inherit the owned process group")
            wait_for_unreaped_exit(leader)

            class UnreapedLeader:
                pid = leader.pid

                def poll(self):
                    raise AssertionError("cleanup polled before signalling the owned group")

                def wait(self, timeout):
                    raise AssertionError("cleanup reaped before signalling the owned group")

            normal_neovim_rpc.cleanup_owned_process_group(
                UnreapedLeader(), group_id, 0
            )
            try:
                normal_neovim_rpc.cleanup_owned_process_group(leader, group_id + 1, 0)
            except ValueError:
                pass
            else:
                raise AssertionError("cleanup accepted a group it did not create")
            leader.wait(timeout=5)
            readable, _, _ = select.select([leader.stdout], [], [], 5)
            if not readable or leader.stdout.read(1) != b"":
                raise AssertionError("owned descendant survived process-group cleanup")
        finally:
            if leader.returncode is None:
                try:
                    os.killpg(group_id, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                leader.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass

    print("normal Neovim RPC descendant cleanup regression passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
