#!/usr/bin/env python3
import argparse
import fcntl
import os
import shutil
import subprocess
import sys
import venv
from pathlib import Path


def run(cmd, env=None, timeout=None):
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, env=env, timeout=timeout)


def ensure_venv(home: Path) -> Path:
    venv_dir = home / "venv"
    python = venv_dir / "bin" / "python"
    if not python.exists():
        venv.EnvBuilder(with_pip=True, clear=False).create(venv_dir)
    return python


def install_deps(python: Path, env):
    marker = python.parent.parent / ".deps-installed"
    packages = [
        "pip",
        "setuptools",
        "wheel",
        "huggingface_hub[hf_xet]",
        "hf_transfer",
        "mlx-audio",
        "soundfile",
    ]
    if marker.exists():
        return
    run([str(python), "-m", "pip", "install", "--upgrade", *packages], env=env)
    marker.write_text("ok\n")


def try_install_aria2c():
    if shutil.which("aria2c"):
        return shutil.which("aria2c")
    brew = shutil.which("brew")
    if not brew:
        return None
    try:
        run([brew, "install", "aria2"], timeout=900)
    except Exception as exc:
        print(f"aria2 install failed, falling back to Hugging Face transfer: {exc}", flush=True)
    return shutil.which("aria2c")


def download_with_aria2(repo_id: str, model_dir: Path, env) -> bool:
    aria2c = shutil.which("aria2c")
    if not aria2c:
        return False
    try:
        from huggingface_hub import HfApi
        api = HfApi()
        files = api.list_repo_files(repo_id=repo_id)
        for file_name in files:
            if file_name.endswith("/") or file_name.startswith(".git"):
                continue
            target = model_dir / file_name
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists() and target.stat().st_size > 0:
                continue
            url = f"https://huggingface.co/{repo_id}/resolve/main/{file_name}"
            run([
                aria2c,
                "--continue=true",
                "--max-connection-per-server=16",
                "--split=16",
                "--min-split-size=1M",
                "--auto-file-renaming=false",
                "--allow-overwrite=true",
                "--dir", str(target.parent),
                "--out", target.name,
                url,
            ], env=env)
        return True
    except Exception as exc:
        print(f"aria2 download failed, falling back to snapshot_download: {exc}", flush=True)
        return False


def snapshot_download(repo_id: str, model_dir: Path, env):
    code = f"""
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id={repo_id!r},
    local_dir={str(model_dir)!r},
    local_dir_use_symlinks=False,
    resume_download=True,
)
"""
    run([env["VENV_PYTHON"], "-c", code], env=env)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", required=True)
    parser.add_argument("--model", required=True)
    args = parser.parse_args()

    home = Path(args.home).expanduser()
    home.mkdir(parents=True, exist_ok=True)
    models_dir = home / "models"
    model_dir = models_dir / args.model.replace("/", "__")
    model_dir.mkdir(parents=True, exist_ok=True)
    locks_dir = home / "locks"
    locks_dir.mkdir(parents=True, exist_ok=True)
    lock_path = locks_dir / f"{args.model.replace('/', '__')}.lock"

    env = os.environ.copy()
    env["HF_HOME"] = str(home / "hf-home")
    env["HF_HUB_ENABLE_HF_TRANSFER"] = "1"
    env["PYTHONUNBUFFERED"] = "1"

    with lock_path.open("w") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        lock_file.write(str(os.getpid()))
        lock_file.flush()

        python = ensure_venv(home)
        env["VENV_PYTHON"] = str(python)
        install_deps(python, env)

        if (model_dir / "config.json").exists():
            print(f"{args.model} already present at {model_dir}", flush=True)
            return

        try_install_aria2c()
        if not download_with_aria2(args.model, model_dir, env):
            snapshot_download(args.model, model_dir, env)

        print(f"Prepared {args.model} at {model_dir}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"bootstrap failed: {exc}", file=sys.stderr, flush=True)
        raise
