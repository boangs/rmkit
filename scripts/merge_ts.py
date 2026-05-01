#!/usr/bin/env python3
"""Merge two .ts files. Base = lupdate-extracted (preferred contexts).
Overlay adds any (context, source) tuples the base is missing. Translations
are pulled from a third .ts (previously translated) by (context, source)
then by source alone as fallback."""
import sys
from xml.etree import ElementTree as ET


def load(path):
    t = ET.parse(path)
    root = t.getroot()
    messages = {}  # (ctx, src) -> message element
    src_only = {}  # src -> message element (first occurrence)
    for ctx_el in root.findall("context"):
        ctx_name = ctx_el.findtext("name") or ""
        for msg in ctx_el.findall("message"):
            src = msg.findtext("source") or ""
            key = (ctx_name, src)
            messages[key] = msg
            src_only.setdefault(src, msg)
    return t, root, messages, src_only


def translation_text(msg):
    tr = msg.find("translation")
    if tr is None:
        return None, None
    if msg.get("numerus") == "yes":
        nfs = tr.findall("numerusform")
        texts = [nf.text for nf in nfs if nf.text]
        return ("numerus", texts) if texts else (None, None)
    return ("plain", tr.text) if tr.text else (None, None)


def apply_translation(msg, kind, value):
    tr = msg.find("translation")
    if tr is None:
        tr = ET.SubElement(msg, "translation")
    # clear existing
    tr.text = None
    for child in list(tr):
        tr.remove(child)
    if kind == "plain":
        tr.text = value
    elif kind == "numerus":
        for v in value:
            nf = ET.SubElement(tr, "numerusform")
            nf.text = v
    if "type" in tr.attrib:
        del tr.attrib["type"]


def main():
    base_path, overlay_path, trans_path, out_path = sys.argv[1:5]

    base_tree, base_root, base_msgs, base_src = load(base_path)
    _, _, overlay_msgs, _ = load(overlay_path)
    _, _, trans_msgs, trans_src = load(trans_path)

    # 1. add missing (ctx, src) from overlay into base
    ctx_map = {c.findtext("name"): c for c in base_root.findall("context")}
    added = 0
    for (ctx, src), msg in overlay_msgs.items():
        if (ctx, src) in base_msgs:
            continue
        # also skip if same source already exists under ANY context in base
        # (likely duplicate)
        # We keep per-context for safety, add to correct context
        if ctx not in ctx_map:
            ctx_el = ET.SubElement(base_root, "context")
            name_el = ET.SubElement(ctx_el, "name")
            name_el.text = ctx
            ctx_map[ctx] = ctx_el
        ctx_map[ctx].append(msg)
        base_msgs[(ctx, src)] = msg
        added += 1

    # 2. pull translations from trans file
    filled = 0
    for key, msg in base_msgs.items():
        ctx, src = key
        kind, val = None, None
        if key in trans_msgs:
            kind, val = translation_text(trans_msgs[key])
        if not kind and src in trans_src:
            kind, val = translation_text(trans_src[src])
        if kind:
            apply_translation(msg, kind, val)
            filled += 1

    # 3. make sure language attr is zh_CN
    base_root.set("language", "zh_CN")

    base_tree.write(out_path, encoding="utf-8", xml_declaration=True)

    total = len(base_msgs)
    print(f"base: {len(base_msgs) - added}, added from overlay: {added}, "
          f"total: {total}, filled translations: {filled}, "
          f"remaining: {total - filled}")


if __name__ == "__main__":
    main()
