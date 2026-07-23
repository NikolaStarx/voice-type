# Ollama LLM Refinement Benchmark

Date: 2026-07-24

## Purpose

Compare the two new local candidates with the three Ollama models already
installed on this Mac for VoiceType's conservative speech-recognition
refinement workload.

The benchmark uses VoiceType's current Oral system prompt and the same
OpenAI-compatible request shape used by the app:

- Endpoint: `http://127.0.0.1:11434/v1/chat/completions`
- Temperature: `0`
- Reasoning effort: `none`
- Streaming: disabled
- One warm-up request per model before timing
- 10 obvious mixed Chinese-English ASR corrections
- 10 already-correct transcripts that must remain exactly unchanged

Run it again with:

```sh
make benchmark-llm
```

Specific models can be selected with:

```sh
make benchmark-llm MODELS="qwen3.5:4b-mlx qwen3.5:2b"
```

## Models

| Ollama tag | Local size | Notes |
|---|---:|---|
| `qwen3.5:0.8b-mlx` | 1.2 GB | Existing official MLX tag |
| `qwen3.5:2b` | 2.7 GB | Existing Ollama model |
| `translategemma:4b` | 3.3 GB | Existing translation-oriented model |
| `bcluzel/LFM2.5-1.2B-Instruct:Q4_K_M` | 731 MB | Community GGUF Q4_K_M |
| `qwen3.5:4b-mlx` | 4.0 GB | New official MLX tag |

Ollama cannot directly serve the Hugging Face
`mlx-community/LFM2.5-1.2B-Instruct-4bit` MLX repository. The closest
Ollama-compatible model was used for the LFM capability comparison. Its
latency is not representative of the native MLX repository.

## Results

`CORR` is correction-task pass count. `KEEP` requires exact preservation.
`BAD` counts empty, heavily shortened/expanded, explanatory, or
Chinese-to-non-Chinese outputs. Latencies are warm wall-clock measurements.

| Model | Total | CORR | KEEP | BAD | P50 | P95 |
|---|---:|---:|---:|---:|---:|---:|
| `qwen3.5:4b-mlx` | **13/20** | 3/10 | **10/10** | **0** | 304 ms | 427 ms |
| `translategemma:4b` | 8/20 | 3/10 | 5/10 | 0 | 478 ms | 600 ms |
| `qwen3.5:0.8b-mlx` | 6/20 | 0/10 | 6/10 | 3 | **108 ms** | **148 ms** |
| `qwen3.5:2b` | 3/20 | 2/10 | 1/10 | 9 | 351 ms | 432 ms |
| `bcluzel/LFM2.5-1.2B-Instruct:Q4_K_M` | 2/20 | 0/10 | 2/10 | 10 | 167 ms | 278 ms |

## Findings

`qwen3.5:4b-mlx` is the clear production candidate from this group. It was
the only model to preserve all ten already-correct transcripts exactly, had
no catastrophic outputs, and remained comfortably below half a second at
P95 on this Mac.

Its seven failures were conservative misses rather than destructive edits.
It did not reliably infer `uv`, `TypeScript`, `GitHub`, `FastAPI`, `MLX`,
`OpenAI`, and `JavaScript` from less common phonetic ASR errors. Those terms
are better handled by profile-specific examples or a deterministic term
dictionary than by selecting a less conservative model.

The 0.8B model is fastest but does almost no useful correction. The 2B model
frequently translates Chinese to English or rewrites correct text.
TranslateGemma is safer than the 2B model but changes wording and punctuation
too often. The community LFM build frequently translates, explains, or
expands the input and is unsuitable for VoiceType's Oral profile.

## Recommendation

Use `qwen3.5:4b-mlx` as the first local model to test interactively in a
separate VoiceType profile. Keep the current profile unchanged until real
dictation confirms the benchmark result. Do not use the tested LFM Ollama
build for automatic text injection.

Sources:

- [Ollama Qwen3.5 tags](https://ollama.com/library/qwen3.5/tags)
- [Ollama LFM community tags](https://ollama.com/bcluzel/LFM2.5-1.2B-Instruct/tags)
- [Hugging Face LFM2.5 MLX repository](https://huggingface.co/mlx-community/LFM2.5-1.2B-Instruct-4bit)
