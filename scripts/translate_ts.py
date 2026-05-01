#!/usr/bin/env python3
"""Translate Qt .ts file to Chinese using DashScope (Qwen) OpenAI-compatible API.

Usage:
    DASHSCOPE_API_KEY=sk-xxx python3 translate_ts.py input.ts output.ts \
        --model qwen3.6-plus --batch 30 --concurrency 5

Strategy: send each batch as JSON {id: source}; ask model to return JSON
{id: translation}. Placeholders like %1 %n <br> must be preserved verbatim.
"""

import argparse
import concurrent.futures
import json
import os
import re
import sys
import time
import urllib.request
import urllib.error
from xml.etree import ElementTree as ET


DEFAULT_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"

SYSTEM_PROMPT = """You are a professional zh-CN (Simplified Chinese) UI translator for a reMarkable e-ink tablet.

Rules:
- Translate the "source" text to natural, concise Simplified Chinese suitable for a consumer UI.
- Keep placeholders like %1 %2 %n %L1 EXACTLY as-is (position may be adjusted to match Chinese grammar).
- Keep HTML tags like <br> <b> <i> <nobr> verbatim, including attributes.
- Keep URLs, email-like tokens, and code identifiers unchanged.
- If source is only placeholders or punctuation (e.g. "%1", "99+"), return it unchanged.
- Do NOT translate brand names: reMarkable, Google, Dropbox, OneDrive, Wi-Fi.
- Match typical iOS/Android Chinese UI conventions (e.g. "Back" -> "返回", "Settings" -> "设置", "Cancel" -> "取消", "Done" -> "完成").
- Use the "context" as a hint for disambiguation; do not include it in your output.
- Return ONLY a single JSON object mapping each id to its Chinese translation — no prose, no code fences."""


def load_ts(path):
    tree = ET.parse(path)
    root = tree.getroot()
    root.set("language", "zh_CN")
    items = []
    for ctx in root.findall("context"):
        ctx_name = ctx.findtext("name") or ""
        for msg in ctx.findall("message"):
            src_el = msg.find("source")
            tr_el = msg.find("translation")
            if src_el is None or tr_el is None:
                continue
            src = src_el.text or ""
            if tr_el.get("type") == "obsolete" or tr_el.get("type") == "vanished":
                continue
            items.append({
                "ctx": ctx_name,
                "source": src,
                "tr_el": tr_el,
                "comment": msg.findtext("comment") or "",
                "extracomment": msg.findtext("extracomment") or "",
            })
    return tree, root, items


SKIP_RE = re.compile(r"^[\s%0-9+\-:/.,()\[\]]*$")


def should_skip(src):
    if not src.strip():
        return True
    if SKIP_RE.match(src):
        return True
    return False


def call_api(url, api_key, model, payload):
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read())


def translate_batch(url, api_key, model, batch):
    payload_items = {}
    for i, it in enumerate(batch):
        entry = {"source": it["source"], "context": it["ctx"]}
        if it["comment"]:
            entry["comment"] = it["comment"]
        if it["extracomment"]:
            entry["extracomment"] = it["extracomment"]
        payload_items[str(i)] = entry
    user_prompt = (
        "Translate these UI strings to Simplified Chinese. Return a single JSON object.\n\n"
        + json.dumps(payload_items, ensure_ascii=False, indent=2)
    )
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_prompt},
        ],
        "response_format": {"type": "json_object"},
        "temperature": 0.2,
    }

    last_err = None
    for attempt in range(4):
        try:
            result = call_api(url, api_key, model, body)
            content = result["choices"][0]["message"]["content"]
            data = json.loads(content)
            return {int(k): v for k, v in data.items()}
        except (urllib.error.HTTPError, urllib.error.URLError, KeyError, json.JSONDecodeError) as e:
            last_err = e
            time.sleep(2 ** attempt)
    raise RuntimeError(f"Batch failed after retries: {last_err}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--model", default="qwen3.6-plus")
    ap.add_argument("--url", default=DEFAULT_URL)
    ap.add_argument("--batch", type=int, default=30)
    ap.add_argument("--concurrency", type=int, default=5)
    args = ap.parse_args()

    api_key = os.environ.get("DASHSCOPE_API_KEY")
    if not api_key:
        print("DASHSCOPE_API_KEY env var required", file=sys.stderr)
        sys.exit(1)

    tree, root, items = load_ts(args.input)
    total = len(items)
    to_translate = []
    already = 0
    for idx, it in enumerate(items):
        if it["tr_el"].text:  # already translated — leave it
            already += 1
            continue
        if should_skip(it["source"]):
            it["tr_el"].text = it["source"]
        else:
            to_translate.append((idx, it))
    print(f"already translated: {already}", file=sys.stderr)
    print(f"total messages: {total}, skipping trivial: {total - len(to_translate)}, "
          f"to translate: {len(to_translate)}", file=sys.stderr)

    batches = []
    for i in range(0, len(to_translate), args.batch):
        batches.append(to_translate[i:i + args.batch])
    print(f"batches: {len(batches)} (size {args.batch}, concurrency {args.concurrency})",
          file=sys.stderr)

    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as ex:
        futures = {
            ex.submit(translate_batch, args.url, api_key, args.model,
                      [b[1] for b in batch]): batch
            for batch in batches
        }
        for fut in concurrent.futures.as_completed(futures):
            batch = futures[fut]
            try:
                result = fut.result()
            except Exception as e:
                print(f"batch error: {e}", file=sys.stderr)
                continue
            for local_i, (orig_idx, it) in enumerate(batch):
                tr = result.get(local_i)
                if tr is None:
                    print(f"missing translation for idx {orig_idx}: {it['source'][:60]!r}",
                          file=sys.stderr)
                    continue
                it["tr_el"].text = tr
            done += 1
            print(f"  progress {done}/{len(batches)}", file=sys.stderr)

    # Strip type="unfinished" from filled translations
    for it in items:
        if it["tr_el"].text:
            if it["tr_el"].get("type") == "unfinished":
                del it["tr_el"].attrib["type"]

    tree.write(args.output, encoding="utf-8", xml_declaration=True)
    print(f"wrote {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
