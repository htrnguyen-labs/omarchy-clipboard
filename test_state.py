#!/usr/bin/env python3
import json
import os
import pathlib
import stat
import subprocess
import tempfile

HELPER = pathlib.Path(__file__).with_name("clipboard-state")


def run(env, *args, data=None, check=True):
    return subprocess.run(
        ["/usr/bin/python3", str(HELPER), *args],
        input=data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        check=check,
    )


def main():
    test_parent = os.environ.get("XDG_RUNTIME_DIR") or os.path.expanduser("~")
    with tempfile.TemporaryDirectory(dir=test_parent) as tmp:
        base = pathlib.Path(tmp)
        env = {"HOME": str(base), "XDG_STATE_HOME": str(base / "state")}
        payload = json.dumps([{"type": "text", "text": "important", "pinned": True}])
        run(env, "write", data=(payload + "\n").encode())
        assert json.loads(run(env, "read").stdout) == json.loads(payload)

        state = base / "state" / "omarchy"
        history = state / "clipboard-history.json"
        assert stat.S_IMODE(state.stat().st_mode) == 0o700
        assert stat.S_IMODE(history.stat().st_mode) == 0o600

        victim = base / "victim"
        victim.write_text("safe")
        history.unlink()
        history.symlink_to(victim)
        run(env, "write", data=b"[]\n")
        assert victim.read_text() == "safe"
        assert history.is_file() and not history.is_symlink()

        image = json.loads(run(env, "image", "image/png", data=b"png").stdout)
        image_path = pathlib.Path(image["path"])
        assert image_path.read_bytes() == b"png"
        assert stat.S_IMODE(image_path.stat().st_mode) == 0o600
        run(env, "write", data=b"[]\n")
        assert not image_path.exists()

        real = base / "real"
        real.mkdir()
        linked = base / "linked"
        linked.symlink_to(real, target_is_directory=True)
        bad_env = {"HOME": str(base), "XDG_STATE_HOME": str(linked)}
        assert run(bad_env, "read", check=False).returncode != 0

        unsafe_home = base / "unsafe-home"
        unsafe_home.mkdir(mode=0o770)
        unsafe_home.chmod(0o770)
        unsafe_home_env = {"HOME": str(unsafe_home)}
        assert run(unsafe_home_env, "read", check=False).returncode != 0

        unsafe_middle = base / "unsafe-middle"
        unsafe_middle.mkdir(mode=0o770)
        unsafe_middle.chmod(0o770)
        unsafe_middle_env = {"HOME": str(base), "XDG_STATE_HOME": str(unsafe_middle / "state")}
        assert run(unsafe_middle_env, "read", check=False).returncode != 0

        unsafe_leaf = base / "unsafe-leaf"
        (unsafe_leaf / "omarchy").mkdir(parents=True, mode=0o770)
        (unsafe_leaf / "omarchy").chmod(0o770)
        unsafe_leaf_env = {"HOME": str(base), "XDG_STATE_HOME": str(unsafe_leaf)}
        assert run(unsafe_leaf_env, "read", check=False).returncode != 0


if __name__ == "__main__":
    main()
