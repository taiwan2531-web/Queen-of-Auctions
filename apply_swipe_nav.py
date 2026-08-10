# -*- coding: utf-8 -*-
"""
把 104woo-assets/swipe-nav.js 掛進所有物件頁
============================================
手機在大圖上左右滑動即可切換上／下一個物件。腳本本身是共用檔（單一真理源），
這支只負責在每頁的 delist.js 之後補上 <script src>。

可重複執行：已經有的頁面會跳過。新物件上架後補跑即可
（publish_new.py 的母版不含這行）。

用法：
  python apply_swipe_nav.py --dry-run
  python apply_swipe_nav.py
"""
import re
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

REPO = Path(__file__).resolve().parent
DRY = "--dry-run" in sys.argv

DELIST = '<script src="../104woo-assets/delist.js"></script>'
SWIPE = '<script src="../104woo-assets/swipe-nav.js"></script>'

added = skipped = nohook = 0
for d in sorted(REPO.glob("w*")):
    if not d.is_dir() or not re.fullmatch(r"w\d+", d.name):
        continue
    f = d / "index.html"
    if not f.exists():
        continue

    t = f.read_text(encoding="utf-8")
    if SWIPE in t:
        skipped += 1
        continue
    if DELIST not in t:
        nohook += 1
        continue

    t = t.replace(DELIST, DELIST + "\n" + SWIPE, 1)
    if not DRY:
        f.write_text(t, encoding="utf-8")
    added += 1

tail = "（DRY，未寫檔）" if DRY else ""
print(f"已掛上 swipe-nav.js：{added} 個頁面{tail}")
if skipped:
    print(f"已存在跳過：{skipped} 個")
if nohook:
    print(f"⚠ 找不到 delist.js 掛載點，未處理：{nohook} 個")
