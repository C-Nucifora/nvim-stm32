#!/usr/bin/env python3
import os
import pathlib
import subprocess
import sys
import tempfile
import time

import normal_neovim_rpc


def group_exists(group_id):
    try:
        os.killpg(group_id, 0)
    except ProcessLookupError:
        return False
    return True


def main():
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
        )
        group_id = leader.pid
        try:
            leader.wait(timeout=5)
            deadline = time.monotonic() + 5
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            if not pid_file.exists():
                raise AssertionError("leader did not record its descendant")
            descendant = int(pid_file.read_text(encoding="utf-8"))
            if os.getpgid(descendant) != group_id:
                raise AssertionError("descendant did not inherit the owned process group")
            if leader.poll() is None:
                raise AssertionError("leader is still running")

            normal_neovim_rpc.cleanup_owned_process_group(leader, group_id, 2)
            if group_exists(group_id):
                raise AssertionError("owned descendant survived process-group cleanup")
            try:
                normal_neovim_rpc.cleanup_owned_process_group(leader, group_id + 1, 0)
            except ValueError:
                pass
            else:
                raise AssertionError("cleanup accepted a group it did not create")
        finally:
            if group_exists(group_id):
                os.killpg(group_id, 9)

    print("normal Neovim RPC descendant cleanup regression passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
