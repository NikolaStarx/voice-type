#!/usr/bin/env python3
import argparse
import fcntl
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


def run(cmd, env=None, timeout=None):
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, env=env, timeout=timeout)


def run_capture(cmd, env=None, timeout=None) -> str:
    print("+", " ".join(cmd), flush=True)
    return subprocess.check_output(cmd, env=env, timeout=timeout, text=True)


def ensure_uv(env) -> str:
    uv = shutil.which("uv", path=env.get("PATH"))
    if uv:
        return uv

    brew = shutil.which("brew", path=env.get("PATH"))
    if brew:
        run([brew, "install", "uv"], env=env, timeout=900)
        uv = shutil.which("uv", path=env.get("PATH"))
        if uv:
            return uv

    raise RuntimeError("uv is required for local ASR setup and could not be found or installed")


def ensure_venv(home: Path, env) -> Path:
    venv_dir = home / "venv"
    python = venv_dir / "bin" / "python"
    marker = venv_dir / ".voice-type-uv"
    uv = ensure_uv(env)
    if not python.exists() or not marker.exists():
        if venv_dir.exists():
            shutil.rmtree(venv_dir)
        run([uv, "venv", "--python", "3.11", str(venv_dir)], env=env, timeout=900)
        marker.write_text("uv\n")
    return python


def install_deps(python: Path, env):
    marker = python.parent.parent / ".deps-installed-uv"
    constraints = python.parent.parent / "constraints.txt"
    constraints.write_text("Cython<3\n")
    env["PIP_CONSTRAINT"] = str(constraints)
    uv = ensure_uv(env)
    packages = [
        "setuptools",
        "wheel",
        "huggingface_hub[hf_xet]",
        "hf_transfer",
        "mlx-audio",
        "soundfile",
    ]
    if marker.exists():
        return
    run([uv, "pip", "install", "--python", str(python), "--upgrade", *packages], env=env)
    marker.write_text("ok\n")


def try_install_aria2c(env):
    path = env.get("PATH")
    if shutil.which("aria2c", path=path):
        return shutil.which("aria2c", path=path)
    brew = shutil.which("brew", path=path)
    if not brew:
        return None
    try:
        run([brew, "install", "aria2"], timeout=900)
    except Exception as exc:
        print(f"aria2 install failed, falling back to Hugging Face transfer: {exc}", flush=True)
    return shutil.which("aria2c", path=path)


def download_with_aria2(repo_id: str, model_dir: Path, env) -> bool:
    aria2c = shutil.which("aria2c", path=env.get("PATH"))
    if not aria2c:
        return False
    try:
        code = f"""
import json
from huggingface_hub import HfApi
print(json.dumps(HfApi().list_repo_files(repo_id={repo_id!r})))
"""
        files = json.loads(run_capture([env["VENV_PYTHON"], "-c", code], env=env))
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


def model_ready(model_dir: Path) -> bool:
    if not (model_dir / "config.json").exists():
        return False

    index = model_dir / "model.safetensors.index.json"
    if index.exists():
        try:
            data = json.loads(index.read_text())
            expected = sorted(set(data.get("weight_map", {}).values()))
        except Exception as exc:
            print(f"could not parse {index}: {exc}", flush=True)
            return False
        if not expected:
            return False
        missing = [
            name for name in expected
            if not (model_dir / name).exists() or (model_dir / name).stat().st_size == 0
        ]
        if missing:
            print(f"model weights missing or empty: {', '.join(missing[:8])}", flush=True)
            return False
        return True

    safetensors = list(model_dir.glob("*.safetensors"))
    return bool(safetensors) and all(path.stat().st_size > 0 for path in safetensors)


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
    env["PATH"] = f"{Path.home()}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + env.get("PATH", "")
    env["HF_HOME"] = str(home / "hf-home")
    env["HF_HUB_ENABLE_HF_TRANSFER"] = "1"
    env["HF_XET_HIGH_PERFORMANCE"] = "1"
    env["PYTHONUNBUFFERED"] = "1"

    with lock_path.open("w") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        lock_file.write(str(os.getpid()))
        lock_file.flush()

        python = ensure_venv(home, env)
        env["VENV_PYTHON"] = str(python)
        install_deps(python, env)

        if model_ready(model_dir):
            print(f"{args.model} already present at {model_dir}", flush=True)
            return

        try_install_aria2c(env)
        if not download_with_aria2(args.model, model_dir, env):
            snapshot_download(args.model, model_dir, env)

        if not model_ready(model_dir):
            raise RuntimeError(f"{args.model} download did not produce complete model weights at {model_dir}")

        print(f"Prepared {args.model} at {model_dir}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"bootstrap failed: {exc}", file=sys.stderr, flush=True)
        raise
