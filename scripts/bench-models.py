#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Thomas Perrot <thomas.perrot@tupi.fr>
# SPDX-License-Identifier: GPL-3.0-only
"""Benchmark Ollama models: prompt and generation speed, load time, tool calls,
image input and, with --container, resident memory.

Used to size the tiers in pull-models.sh; re-run it after an Ollama bump or
before changing the catalogue. Thinking is disabled for every request, as the
stack does for background tasks.

Examples (models must already be pulled):
  ./scripts/bench-models.py qwen3.5:4b ministral-3:3b
  ./scripts/bench-models.py --ctx 16384 --vision --container llm-companion-ollama gemma4:e4b
  ./scripts/bench-models.py --url http://127.0.0.1:11434 --runs 5 mimo-v2.6:9b

--url defaults to http://127.0.0.1:11434, which the stack does not publish:
run it inside the pod (podman exec) or against a separate Ollama instance.
"""
import argparse
import base64
import json
import statistics
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zlib

def prompt_body(run):
    """~1.5-2K tokens of shell script (per tokenizer), standing in for a file an agent reads.

    Every line depends on the run number: Ollama reuses cached chunks of a
    prompt, not only a shared prefix, so varying one line is not enough.
    """
    return "\n".join(
        f'check_{run}_{i}() {{ local url="$1"; code=$(curl -s -o /dev/null -w "%{{http_code}}" "$url"); '
        f'[[ "$code" == "200" ]] && echo "ok {run}.{i}" || {{ echo "fail {run}.{i}: $code"; rc=1; }}; }}'
        for i in range(20))
TOOLS = [{"type": "function", "function": {
    "name": "get_weather", "description": "Get the current weather for a city",
    "parameters": {"type": "object", "properties": {"city": {"type": "string"}},
                   "required": ["city"]}}}]


def png_red_square():
    """64x64 PNG: white background, red square in the middle."""
    rows = b"".join(
        b"\x00" + b"".join(b"\xff\x00\x00" if 16 <= x < 48 and 16 <= y < 48 else b"\xff\xff\xff"
                           for x in range(64))
        for y in range(64))

    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


class Ollama:
    def __init__(self, url):
        self.url = url.rstrip("/")

    def post(self, path, body, timeout=900):
        req = urllib.request.Request(self.url + path, json.dumps(body).encode(),
                                     {"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.load(r), None
        except urllib.error.HTTPError as e:
            return None, f"HTTP {e.code}: {e.read().decode()[:160]}"
        except (urllib.error.URLError, TimeoutError) as e:
            return None, str(e)

    def loaded(self):
        with urllib.request.urlopen(self.url + "/api/ps", timeout=30) as r:
            return [m["name"] for m in json.load(r).get("models", [])]

    def unload(self, model):
        self.post("/api/generate", {"model": model, "keep_alive": 0})
        for _ in range(60):
            if not self.loaded():
                return
            time.sleep(1)

    def chat(self, model, ctx, messages, tools=None, predict=256):
        body = {"model": model, "messages": messages, "stream": False, "think": False,
                "options": {"num_ctx": ctx, "num_predict": predict, "temperature": 0, "seed": 1}}
        if tools:
            body["tools"] = tools
        return self.post("/api/chat", body)


def anon_gb(container):
    """Anonymous memory of the container's cgroup: weights plus KV cache and buffers."""
    out = subprocess.run(["podman", "exec", container, "cat", "/sys/fs/cgroup/memory.stat"],
                         capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        key, value = line.split()
        if key == "anon":
            return int(value) / 1e9
    return float("nan")


def bench(api, model, args):
    res = {"model": model}
    api.unload(model)
    base = anon_gb(args.container) if args.container else None

    r, err = api.chat(model, args.ctx, [{"role": "user", "content": "Say OK."}], predict=8)
    if err:
        res["error"] = err
        return res
    res["load_s"] = r.get("load_duration", 0) / 1e9

    prompt_tps, gen_tps = [], []
    for i in range(args.runs):
        msg = f"{prompt_body(i)}\n\nIn three bullet points, explain what these functions do."
        r, err = api.chat(model, args.ctx, [{"role": "user", "content": msg}])
        if err:
            res["error"] = err
            return res
        prompt_tps.append(r["prompt_eval_count"] / (r["prompt_eval_duration"] / 1e9))
        gen_tps.append(r["eval_count"] / (r["eval_duration"] / 1e9))
    res["prompt_tokens"] = r["prompt_eval_count"]
    res["prompt_tps"] = statistics.median(prompt_tps)
    res["gen_tps"] = statistics.median(gen_tps)
    if args.container:
        res["ram_gb"] = anon_gb(args.container) - base

    r, err = api.chat(model, args.ctx, [{"role": "user", "content": "What is the weather in Lyon right now?"}],
                      tools=TOOLS, predict=128)
    calls = [] if err else ((r.get("message") or {}).get("tool_calls") or [])
    res["tools"] = "ok" if any(c["function"]["name"] == "get_weather" for c in calls) else (
        "error" if err else "no call")

    if args.vision:
        image = base64.b64encode(png_red_square()).decode()
        r, err = api.chat(model, args.ctx, [{"role": "user", "images": [image],
                                             "content": "What color is the square? Answer with one word."}],
                          predict=16)
        answer = "" if err else (r.get("message") or {}).get("content", "")
        res["vision"] = "ok" if "red" in answer.lower() else "wrong"

    api.unload(model)
    return res


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("models", nargs="+", help="model tags, already pulled")
    parser.add_argument("--url", default="http://127.0.0.1:11434", help="Ollama base URL")
    parser.add_argument("--ctx", type=int, default=4096, help="num_ctx for every request")
    parser.add_argument("--runs", type=int, default=3, help="measured runs per model (median)")
    parser.add_argument("--vision", action="store_true", help="also check image input")
    parser.add_argument("--container", help="Ollama container name, to measure resident memory")
    parser.add_argument("--json", action="store_true", help="print one JSON object per model")
    args = parser.parse_args()

    api = Ollama(args.url)
    if not args.json:
        print(f"{'model':28} {'prompt t/s':>10} {'gen t/s':>8} {'load s':>7} "
              f"{'RAM GB':>7} {'tools':>8} {'vision':>7}")
    failed = False
    for model in args.models:
        res = bench(api, model, args)
        failed |= "error" in res
        if args.json:
            print(json.dumps(res), flush=True)
        elif "error" in res:
            print(f"{model:28} error: {res['error']}", flush=True)
        else:
            ram = f"{res['ram_gb']:7.2f}" if "ram_gb" in res else f"{'-':>7}"
            print(f"{model:28} {res['prompt_tps']:10.0f} {res['gen_tps']:8.1f} {res['load_s']:7.1f} "
                  f"{ram} {res['tools']:>8} {res.get('vision', '-'):>7}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
