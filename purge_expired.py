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
import time
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
ap.add_argument("--stats-out", help="把統計寫成 JSON（給自動化腳本判斷，不必解析中文輸出）")
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


def write_stats(**kw):
    if not args.stats_out:
        return
    with open(args.stats_out, "w", encoding="utf-8") as f:
        json.dump(kw, f, ensure_ascii=False, indent=2)

print(f"總物件 {len(items)}｜保留 {len(keep)}｜應刪除 {len(purge_codes)}")
write_stats(purge=len(purge_codes), kept=len(keep), total=len(items),
            dry_run=args.dry_run, done=False)
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
#    ⚠ repo 在 Google Drive 的虛擬檔案系統上（偽裝成 FAT32，Get-Volume 讀不到），
#      剛寫入的檔案不保證立刻被 git 看到。
#      2026-10-13：122 個資料夾刪除進了 commit，但 104woo.html 與 124 頁導覽修補
#      沒進去，線上 BASE_ITEMS 一度指向已刪除的物件。
def stage_all():
    git("add", "-A", "--", "104woo.html", *[c for c in purge_codes])
    for it in kept_sorted:
        git("add", "--", f"{it['code']}/index.html")


# ---- 核對用的三個檢查 ----
#
# 🔴 不要用 `git status` 當核對依據。
# 2026-10-26 的鐵證：下面這段核對當時已經存在（a6cc07b 00:05:26，
# 比清除 commit a45264d 00:08:38 早三分鐘），卻仍讓 w629/index.html 漏出去。
# 因為它信任 git status——repo 開了 core.fsmonitor，status 回報工作區乾淨，
# 而磁碟上的 w629/index.html 跟 HEAD 其實不一樣。
# 核對邏輯沒錯，錯在它建立在一個會說謊的指令上。
# 後果：工作區從此永遠不乾淨 → 四次排程連續 exit 3 → 13 天無聲空轉。
#
# 所以改用 git hash-object 把磁碟內容重算一次 oid，跟 HEAD 版的 blob oid 比對。
# hash-object 會套用與 commit 相同的 clean filter（autocrlf / .gitattributes），
# 所以不能直接拿 `git show` 的位元去比——text 檔的換行會被轉換而全部誤判。
# 兩邊都只用一次 git 呼叫，548 個檔案約一秒。


def head_oids():
    """HEAD 版所有檔案的 blob oid。一次 git 呼叫。"""
    out = {}
    for ln in git("ls-tree", "-r", "HEAD").stdout.splitlines():
        meta, _, path = ln.partition("\t")
        parts = meta.split()
        if len(parts) == 3:
            out[path] = parts[2]
    return out


def disk_oids(paths):
    """磁碟內容重算的 blob oid。一次 git 呼叫，不讀 index、不問 fsmonitor。"""
    if not paths:
        return {}
    r = subprocess.run(["git", "-C", REPO, "hash-object", "--stdin-paths"],
                       input="\n".join(paths) + "\n", capture_output=True,
                       text=True, encoding="utf-8", errors="ignore")
    oids = r.stdout.split()
    if r.returncode != 0 or len(oids) != len(paths):
        return {}
    return dict(zip(paths, oids))


def differs_from_head():
    """磁碟內容 != HEAD 版的產線檔案。回傳路徑清單；空清單代表 commit 完整。"""
    want = ["104woo.html"] + [f"{it['code']}/index.html" for it in kept_sorted]
    want = [p for p in want if os.path.exists(os.path.join(REPO, p))]
    h = head_oids()
    d = disk_oids(want)
    if not d:
        return ["(hash-object 失敗，無法核對)"]
    return [p for p in want if h.get(p) != d.get(p)]


def broken_nav():
    """導覽連結指向不存在的資料夾。純讀磁碟，完全不經過 git。

    這是 2026-10-13 線上實際壞掉的形狀：BASE_ITEMS 筆數對、工作區「看起來」乾淨，
    但總覽與物件頁指向已被刪掉的物件。筆數相符不代表結構一致。
    """
    exist = {d for d in os.listdir(REPO) if re.fullmatch(r"w\d+", d)}
    bad = []
    for c in sorted(exist):
        p = os.path.join(REPO, c, "index.html")
        if not os.path.exists(p):
            continue
        body = io.open(p, encoding="utf-8", errors="ignore").read()
        for t in re.findall(r'href="\.\./(w\d+)/"', body):
            if t not in exist:
                bad.append(f"{c} -> {t}")
    return bad


def disk_mismatch():
    """磁碟上的 BASE_ITEMS 與資料夾是否一一對應。純讀磁碟。"""
    body = io.open(HTML, encoding="utf-8").read()
    in_html = set(re.findall(r'"code":"(w\d+)"', body))
    on_disk = {d for d in os.listdir(REPO) if re.fullmatch(r"w\d+", d)}
    return sorted(in_html - on_disk), sorted(on_disk - in_html)


def head_count():
    return len(set(re.findall(r'"code":"(w' + r'\d+)"',
                              git('show', 'HEAD:104woo.html').stdout)))


# ---- 建立 commit ----
# 記下 commit 前的 HEAD：只有「本次確實建立了新 commit」才可以 amend。
# 否則 amend 會改寫上一個 commit，而那個很可能已經推送出去了（主張 4）。
pre_head = git("rev-parse", "HEAD").stdout.strip()
stage_all()
r = git("commit", "-m",
        f"chore: 清除下架滿 {args.days} 天的物件（{len(purge_codes)} 筆：{purge_codes[0]}–{purge_codes[-1]}）\n\n"
        f"依 delist.js 規則（開標+3h 下架）再滿 {args.days} 天即刪除；"
        f"總覽 {len(items)} → {len(keep)} 筆，並修補相鄰物件導覽鏈。")
print(r.stdout.strip()[:200] if r.returncode == 0 else "（無變更或 commit 失敗）")
ours = git("rev-parse", "HEAD").stdout.strip() != pre_head
if not ours:
    print("  ⚠ 本次沒有建立新 commit，之後一律不 amend（避免改寫已推送的歷史）")

# ---- 重試到磁碟內容與 HEAD 一致為止，最多 60 秒 ----
# 固定重試次數不夠：2026-10-26 清 61 筆時 104woo.html 延遲到第 2 次之後才可見，
# 迴圈已因為「這次沒東西可 stage」而提早結束，commit 裡仍是舊的 587 筆。
deadline = time.time() + 60
while True:
    missing = differs_from_head()
    if not missing:
        break
    stage_all()
    if git("diff", "--cached", "--quiet").returncode != 0:
        if ours:
            git("commit", "--amend", "--no-edit")
            print(f"  ↳ 補上延遲才可見的檔案（{len(missing)} 個）")
        else:
            git("commit", "-m", "fix(purge): 補上延遲才可見的檔案")
            ours = True
            print(f"  ↳ 另開 commit 補上延遲才可見的檔案（{len(missing)} 個）")
    if time.time() > deadline:
        break
    time.sleep(3)

# ---- 核對：三道都要過，否則不推送 ----
problems = []

missing = differs_from_head()
if missing:
    problems.append(f"磁碟內容與 HEAD 版不一致的檔案 {len(missing)} 個："
                    + "、".join(missing[:8]) + ("…" if len(missing) > 8 else ""))

in_head = head_count()
if in_head != len(keep):
    problems.append(f"HEAD 版 BASE_ITEMS {in_head} 筆、應為 {len(keep)} 筆")

only_html, only_disk = disk_mismatch()
if only_html or only_disk:
    problems.append(f"BASE_ITEMS 與資料夾不對應：只在總覽 {only_html[:5]}、只在磁碟 {only_disk[:5]}")

nav = broken_nav()
if nav:
    problems.append(f"導覽連結指向不存在的物件 {len(nav)} 筆：" + "、".join(nav[:8]))

if problems:
    print("")
    print("❌ commit 內容與預期不符，不推送：")
    for p in problems:
        print(f"   - {p}")
    left = git("status", "--porcelain").stdout.strip()
    if left:
        print("   git status 回報的變動（注意：開了 fsmonitor 時這份可能不可信）：")
        for ln in left.splitlines()[:10]:
            print("    ", ln)
    print("   ⚠ 請人工確認後再處理。")
    sys.exit(2)
print(f"核對通過：HEAD 版 BASE_ITEMS {in_head} 筆、"
      f"磁碟與 HEAD 逐檔一致、BASE_ITEMS ⇔ 資料夾一一對應、導覽無壞連結")
write_stats(purge=len(purge_codes), kept=len(keep), total=len(items),
            dry_run=False, done=True, deleted=purge_codes)

if args.push:
    p = git("push", "origin", "main")
    print("✅ 已推送" if p.returncode == 0 else f"⚠ push 失敗：{(p.stderr or '')[:200]}")
