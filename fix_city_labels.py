# -*- coding: utf-8 -*-
"""
修正縣市標籤錯置
================
104 法拍網用「查詢縣市」標記物件，但查嘉義縣會一併回傳嘉義市的物件，
行政區欄位還被縮寫成「嘉市」。結果是：
  - 客戶用縣市篩選找嘉義市，這些物件不會出現（被歸在嘉義縣）
  - 卡片顯示「嘉義縣｜嘉市」
  - 新批產線還會把「嘉市」寫進物件名稱與語音講稿（「座落嘉義縣嘉市」）

判斷規則（一般化，不只嘉義）：
  1. 地址開頭的縣市 != BASE_ITEMS 的 city  ->  以地址為準修正 city
  2. dist 不出現在地址裡（例「嘉市」）     ->  視為無效行政區，清空
  3. 物件名稱以舊 dist 開頭                ->  去掉該前綴
  4. feat／講稿中的「座落<舊city><舊dist>」 ->  改為「座落<新city>」

同時修 BASE_ITEMS 與各物件頁 index.html。可重複執行（已正確的不會再動）。

用法：
  python fix_city_labels.py --dry-run
  python fix_city_labels.py
"""
import json
import re
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

REPO = Path(__file__).resolve().parent
HTML_104 = REPO / "104woo.html"
DRY = "--dry-run" in sys.argv

CITY_RE = re.compile(r"^(.{1,3}?[縣市])")


def load_base_items():
    html = HTML_104.read_text(encoding="utf-8")
    m = re.search(r"const BASE_ITEMS = (\[.*?\]);\r?\nconst QUEEN_IMG", html, re.S)
    if not m:
        sys.exit("104woo.html 裡找不到 BASE_ITEMS")
    return json.loads(m.group(1)), html, m


def real_city(addr):
    m = CITY_RE.match(str(addr or ""))
    return m.group(1) if m else None


PREV_RE = re.compile(r'(<a href="\.\./(w\d+)/">⬅ 上物件｜)([^<]*?)(</a>)')
NEXT_RE = re.compile(r'(<a href="\.\./(w\d+)/">下物件｜)([^<]*?)( ➡</a>)')


def sync_nav_names(items):
    """把各物件頁「上物件／下物件」連結顯示的名稱，同步成 BASE_ITEMS 的現行名稱。

    物件改名時，改的是它自己的頁面；相鄰兩頁的導覽連結仍寫著舊名稱。
    這一段每次都跑（冪等），確保不會有殘留的舊名稱。
    """
    names = {i["code"]: i.get("name", "") for i in items if i.get("code")}

    def repl(mm):
        want = names.get(mm.group(2))
        return mm.group(1) + (want if want else mm.group(3)) + mm.group(4)

    changed = 0
    for code in names:
        f = REPO / code / "index.html"
        if not f.exists():
            continue
        t = f.read_text(encoding="utf-8")
        new = NEXT_RE.sub(repl, PREV_RE.sub(repl, t))
        if new != t:
            if not DRY:
                f.write_text(new, encoding="utf-8")
            changed += 1
    return changed


def main():
    items, html, m = load_base_items()
    fixed = []

    for it in items:
        addr = str(it.get("addr") or "")
        city = str(it.get("city") or "")
        dist = str(it.get("dist") or "")
        rc = real_city(addr)
        if not rc or not city or rc == city:
            continue

        old = {"city": city, "dist": dist, "name": it.get("name"), "feat": it.get("feat")}
        it["city"] = rc
        # dist 沒出現在地址裡就是無效的縮寫（例「嘉市」），清空
        new_dist = dist if (dist and dist in addr) else ""
        it["dist"] = new_dist

        # 物件名稱誤帶舊行政區前綴
        name = str(it.get("name") or "")
        if dist and name.startswith(dist):
            it["name"] = name[len(dist):]

        # feat 講稿裡的「座落<舊city><舊dist>」
        if it.get("feat"):
            it["feat"] = str(it["feat"]).replace(f"座落{city}{dist}", f"座落{rc}")

        fixed.append((it["code"], old, {"city": it["city"], "dist": it["dist"],
                                        "name": it.get("name"), "feat": it.get("feat")}))

    if not fixed:
        print("縣市標籤：沒有需要修正的物件。")
        n = sync_nav_names(items)
        print(f"導覽連結名稱同步：{n} 個頁面已更新{'（DRY，未寫檔）' if DRY else ''}")
        return

    print(f"需修正 {len(fixed)} 筆：")
    for code, o, n in fixed[:5]:
        print(f"  [{code}] {o['city']}｜{o['dist']}  ->  {n['city']}｜{n['dist'] or '（無）'}")
        if o["name"] != n["name"]:
            print(f"        名稱 {o['name']}  ->  {n['name']}")
    if len(fixed) > 5:
        print(f"  …其餘 {len(fixed) - 5} 筆同樣處理")

    # ---- 寫回 BASE_ITEMS ----
    new_json = json.dumps(items, ensure_ascii=False, separators=(",", ":"))
    new_html = html[:m.start(1)] + new_json + html[m.end(1):]
    if not DRY:
        HTML_104.write_text(new_html, encoding="utf-8")
    print(f"\n104woo.html BASE_ITEMS 已更新{'（DRY，未寫檔）' if DRY else ''}")

    # ---- 修各物件頁 ----
    pages = 0
    for code, o, n in fixed:
        f = REPO / code / "index.html"
        if not f.exists():
            continue
        t = f.read_text(encoding="utf-8")
        orig = t
        # chip：「舊city｜舊dist」-> 「新city」（新 dist 為空就不留分隔線）
        t = t.replace(f"{o['city']}｜{o['dist']}", n["city"] + (f"｜{n['dist']}" if n["dist"] else ""))
        t = t.replace(f"座落{o['city']}{o['dist']}", f"座落{n['city']}")
        # 物件名稱出現在 title／og／h1／alt／基本資料，整串換掉最安全
        if o["name"] and n["name"] and o["name"] != n["name"]:
            t = t.replace(o["name"], n["name"])
        if t != orig:
            if not DRY:
                f.write_text(t, encoding="utf-8")
            pages += 1

    print(f"物件頁已修正 {pages} 個{'（DRY，未寫檔）' if DRY else ''}")

    n = sync_nav_names(items)
    print(f"導覽連結名稱同步：{n} 個頁面已更新{'（DRY，未寫檔）' if DRY else ''}")
    changed_narr = [c for c, o, n in fixed
                    if (o["feat"] != n["feat"]) or (o["name"] != n["name"])]
    if changed_narr:
        print(f"\n⚠ 其中 {len(changed_narr)} 筆的講稿內容有變，若已有 voice.mp3 需刪除重生：")
        print("  " + "、".join(changed_narr[:12]) + ("…" if len(changed_narr) > 12 else ""))


if __name__ == "__main__":
    main()
