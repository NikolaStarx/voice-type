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

    def transcribe(self, repo_id: str, audio_path: str, language: str) -> str:
        from mlx_audio.stt import load

        model_path = self.model_path(repo_id)
        if model_path not in self.loaded:
            self.loaded[model_path] = load(model_path)
        model = self.loaded[model_path]
        kwargs = {}
        mapped_language = language_name(language)
        if mapped_language:
            kwargs["language"] = mapped_language
        result = model.generate(audio_path, **kwargs)
        if isinstance(result, str):
            return result.strip()
        if isinstance(result, dict):
            for key in ("text", "transcription", "result"):
                value = result.get(key)
                if isinstance(value, str):
                    return value.strip()
        text = getattr(result, "text", None)
        if isinstance(text, str):
            return text.strip()
        return str(result).strip()


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
                text = cache.transcribe(repo_id, audio_path, language)
                self.respond_json({"text": text})
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
