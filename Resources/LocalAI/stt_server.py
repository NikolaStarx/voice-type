#!/usr/bin/env python3
import argparse
import json
import os
import sys
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class ModelCache:
    def __init__(self, home: Path):
        self.home = home
        self.loaded = {}

    def model_path(self, repo_id: str) -> str:
        local = self.home / "models" / repo_id.replace("/", "__")
        if (local / "config.json").exists():
            return str(local)
        return repo_id

    def transcribe(self, repo_id: str, audio_path: str, language: str):
        from mlx_audio.stt import load

        model_path = self.model_path(repo_id)
        if model_path not in self.loaded:
            self.loaded[model_path] = load(model_path)
        model = self.loaded[model_path]
        audio_stats = inspect_audio(Path(audio_path))
        kwargs = {}
        mapped_language = language_name(language)
        if mapped_language:
            kwargs["language"] = mapped_language
        result = model.generate(audio_path, **kwargs)
        if isinstance(result, str):
            return result.strip(), audio_stats
        if isinstance(result, dict):
            for key in ("text", "transcription", "result"):
                value = result.get(key)
                if isinstance(value, str):
                    return value.strip(), audio_stats
        text = getattr(result, "text", None)
        if isinstance(text, str):
            return text.strip(), audio_stats
        return str(result).strip(), audio_stats


def inspect_audio(audio_path: Path):
    try:
        import numpy as np
        import soundfile as sf

        data, sample_rate = sf.read(str(audio_path), dtype="float32", always_2d=True)
        frame_count = int(data.shape[0])
        if frame_count == 0:
            stats = {
                "input_path": str(audio_path),
                "sample_rate": int(sample_rate),
                "frames": 0,
                "raw_peak": 0.0,
                "raw_rms": 0.0,
            }
            print("audio_inspect " + json.dumps(stats, ensure_ascii=False, sort_keys=True), flush=True)
            return stats

        mono = data.mean(axis=1)
        raw_peak = float(np.max(np.abs(mono)))
        raw_rms = float(np.sqrt(np.mean(np.square(mono, dtype=np.float64))))

        stats = {
            "input_path": str(audio_path),
            "sample_rate": int(sample_rate),
            "frames": frame_count,
            "raw_peak": raw_peak,
            "raw_rms": raw_rms,
        }
        print("audio_inspect " + json.dumps(stats, ensure_ascii=False, sort_keys=True), flush=True)
        return stats
    except Exception as exc:
        stats = {
            "input_path": str(audio_path),
            "error": str(exc),
        }
        print("audio_inspect_failed " + json.dumps(stats, ensure_ascii=False, sort_keys=True), flush=True)
        return stats


def language_name(code: str) -> str:
    mapping = {
        "en-US": "English",
        "zh-CN": "Chinese",
        "zh-TW": "Chinese",
        "ja-JP": "Japanese",
        "ko-KR": "Korean",
    }
    return mapping.get(code, code)


def make_handler(cache: ModelCache):
    class Handler(BaseHTTPRequestHandler):
        server_version = "VoiceTypeLocalASR/1.0"

        def do_GET(self):
            if self.path == "/health":
                self.respond_json({"ok": True})
            else:
                self.send_error(404)

        def do_POST(self):
            if self.path != "/transcribe":
                self.send_error(404)
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
                audio_path = payload.get("audio_path", "")
                repo_id = payload.get("model", "")
                language = payload.get("language", "")
                if not audio_path or not repo_id:
                    self.send_error(400, "audio_path and model are required")
                    return
                text, audio_stats = cache.transcribe(repo_id, audio_path, language)
                self.respond_json({"text": text, "audio": audio_stats})
            except Exception as exc:
                traceback.print_exc()
                self.respond_json({"error": str(exc)}, status=500)

        def log_message(self, fmt, *args):
            sys.stdout.write("%s - %s\n" % (self.address_string(), fmt % args))
            sys.stdout.flush()

        def respond_json(self, payload, status=200):
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()

    home = Path(args.home).expanduser()
    os.environ.setdefault("HF_HOME", str(home / "hf-home"))
    cache = ModelCache(home)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(cache))
    print(f"VoiceType local ASR server listening on 127.0.0.1:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
