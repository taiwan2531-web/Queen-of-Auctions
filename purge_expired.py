# -*- coding: utf-8 -*-
"""
清除下架滿 N 天的物件
=====================
規則（與 104woo-assets/delist.js 一致）：
  開標時刻 + DELIST_HOURS(3) 小時 → 下架
  下架後再滿 PURGE_DAYS(30) 天    → 刪除物件

保留期為什麼是 30 天（2026-08-22 改）：
  流標後重新排拍的物件，案號不變。只要它還留在 BASE_ITEMS，
  publish_new.py 就能「同案號就地更新」，代號與 tinyurl 短網址不變，
  已發出去的連結不會失效；被刪掉的話就只能開新代號、舊連結報廢。
  一拍到二拍實測間隔約 21～35 天，爬蟲每 8～11 天跑一次，30 天足以涵蓋。

刪除內容：
  1. wNNN/ 資料夾（index.html、photo/map.jpg、voice.mp3）
  2. 104woo.html 的 BASE_ITEMS 中該筆資料
  3. 修補相鄰物件頁的「上物件／下物件」導覽鏈

用法：
  python purge_expired.py --dry-run     # 只列出，不刪除（建議先跑）
  python purge_expired.py               # 實際刪除並 commit
  python purge_expired.py --days 7      # 改用 7 天保留期（舊預設）
  python purge_expired.py --push        # 刪除後一併 push
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone

sys.stdout.reconfigure(encoding="utf-8")

REPO = os.path.dirname(os.path.abspath(__file__))
HTML = os.path.join(REPO, "104woo.html")
TZ = timezone(timedelta(hours=8))
DELIST_HOURS = 3

ap = argparse.ArgumentParser()
ap.add_argument("--days", type=int, default=30, help="下架後保留天數（預設 30）")
ap.add_argument("--dry-run", action="store_true", help="只列出不刪除")
ap.add_argument("--push", action="store_true", help="刪除後 push 到 GitHub")
args = ap.parse_args()


def auc_start(iso, time_s):
    """開標時刻；time 為 00:00／空／無法解析時視為未知，保守以 17:00 起算（同 delist.js）"""
    if not iso:
        return None
    m = re.search(r"(\d{1,2}):(\d{2})", str(time_s or "").replace("：", ":"))
    hh, mm = "17", "00"
    if m and not (m.group(1).zfill(2) == "00" and m.group(2) == "00"):
        hh, mm = m.group(1).zfill(2), m.group(2)
    try:
        return datetime.fromisoformat(f"{iso}T{hh}:{mm}:00+08:00")
    except ValueError:
        return None


def git(*a, check=False):
    r = subprocess.run(["git", "-C", REPO] + list(a), capture_output=True,
                       text=True, encoding="utf-8", errors="ignore")
    if check and r.returncode != 0:
        print(f"  ⚠ git {' '.join(a[:2])}: {(r.stderr or r.stdout)[:200]}")
    return r


now = datetime.now(TZ)
html = open(HTML, encoding="utf-8").read()
m = re.search(r"const BASE_ITEMS = (\[.*?\]);\r?\nconst QUEEN_IMG", html, re.S)
items = json.loads(m.group(1))

purge_codes, keep = [], []
for i in items:
    t = auc_start(i.get("dateISO"), i.get("time"))
    if t is not None and now >= t + timedelta(hours=DELIST_HOURS) + timedelta(days=args.days):
        purge_codes.append(i["code"])
    else:
        keep.append(i)

print(f"現在 {now:%Y-%m-%d %H:%M}｜保留期 {args.days} 天")
print(f"總物件 {len(items)}｜保留 {len(keep)}｜應刪除 {len(purge_codes)}")
if not purge_codes:
    print("沒有需要刪除的物件。")
    sys.exit(0)
print(f"刪除範圍：{purge_codes[0]} … {purge_codes[-1]}")

if args.dry_run:
    print("\n[DRY-RUN] 未做任何變更。")
    sys.exit(0)

purge_set = set(purge_codes)

# 1) 刪除資料夾
removed = 0
for code in purge_codes:
    d = os.path.join(REPO, code)
    if os.path.isdir(d):
        shutil.rmtree(d, ignore_errors=True)
        removed += 1

# 2) 修補保留物件的導覽鏈（依代號排序重建上/下物件）
kept_sorted = sorted(keep, key=lambda x: int(x["code"][1:]))
by_code = {x["code"]: x for x in kept_sorted}
patched = 0
for idx, it in enumerate(kept_sorted):
    page = os.path.join(REPO, it["code"], "index.html")
    if not os.path.exists(page):
        continue
    h = open(page, encoding="utf-8").read()
    orig = h
    prev_it = kept_sorted[idx - 1] if idx > 0 else None
    next_it = kept_sorted[idx + 1] if idx < len(kept_sorted) - 1 else None
    prev_html = (f'<a href="../{prev_it["code"]}/">⬅ 上物件｜{prev_it["name"]}</a>'
                 if prev_it else '<a class="off" href="#">⬅ 上物件</a>')
    next_html = (f'<a href="../{next_it["code"]}/">下物件｜{next_it["name"]} ➡</a>'
                 if next_it else '<a class="off" href="#">下物件 ➡</a>')
    h = re.sub(r'<a(?: class="off")? href="(?:\.\./w\d+/|#)">⬅ 上物件[^<]*</a>', prev_html, h, count=1)
    h = re.sub(r'<a(?: class="off")? href="(?:\.\./w\d+/|#)">下物件[^<]*</a>', next_html, h, count=1)
    if h != orig:
        open(page, "w", encoding="utf-8").write(h)
        patched += 1

# 3) 更新 BASE_ITEMS
new_json = json.dumps(keep, ensure_ascii=False, separators=(",", ":"))
open(HTML, "w", encoding="utf-8").write(html[:m.start(1)] + new_json + html[m.end(1):])

print(f"\n已刪除資料夾 {removed} 個｜修補導覽 {patched} 頁｜BASE_ITEMS {len(items)} → {len(keep)}")

# 4) commit
git("add", "-A", "--", "104woo.html", *[c for c in purge_codes])
for it in kept_sorted:
    git("add", "--", f"{it['code']}/index.html")
r = git("commit", "-m",
        f"chore: 清除下架滿 {args.days} 天的物件（{len(purge_codes)} 筆：{purge_codes[0]}–{purge_codes[-1]}）\n\n"
        f"依 delist.js 規則（開標+3h 下架）再滿 {args.days} 天即刪除；"
        f"總覽 {len(items)} → {len(keep)} 筆，並修補相鄰物件導覽鏈。")
print(r.stdout.strip()[:200] if r.returncode == 0 else "（無變更或 commit 失敗）")

if args.push:
    p = git("push", "origin", "main")
    print("✅ 已推送" if p.returncode == 0 else f"⚠ push 失敗：{(p.stderr or '')[:200]}")
