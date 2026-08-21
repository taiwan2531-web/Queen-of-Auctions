# -*- coding: utf-8 -*-
"""
本機 GPU 批次補語音
===================
與雲端 sync_voices.py 等價，但：
  - VoxCPM2 模型只載入一次（省下每筆 ~12 秒重載）
  - 直接讀寫本機檔案（不逐筆打 GitHub API）
  - 每 N 筆 commit 一次，最後統一 push

用法：
  python local_voice_batch.py            # 全部補完
  python local_voice_batch.py --limit 5  # 只做 5 筆（試跑）
"""
import os, re, sys, time, subprocess, argparse

sys.stdout.reconfigure(encoding="utf-8")

# 自動定位到本腳本所在的 repo，不寫死路徑
#（2026-08-22：專案曾有兩份 clone，寫死會把語音生成到已封存的那一份）
REPO = os.path.dirname(os.path.abspath(__file__))
VOICE_DIR = os.path.join(REPO, "voices", "法拍女王 陳慧瑜")
REF_WAV = os.path.join(VOICE_DIR, "ref_voice.wav")
PROMPT_TXT = os.path.join(VOICE_DIR, "prompt.txt")
COMMIT_EVERY = 10

# ffmpeg：winget 安裝後 PATH 需重開 shell 才生效，故直接指向實體路徑。
# 資料夾名含版本號（ffmpeg-9.0-full_build），會隨更新改變，所以用萬用字元找最新的一個。
import glob
_FF_GLOB = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Microsoft", "WinGet", "Packages",
                        "Gyan.FFmpeg_*", "ffmpeg-*-full_build", "bin", "ffmpeg.exe")
_FF = sorted(glob.glob(_FF_GLOB))
FFMPEG = _FF[-1] if _FF else "ffmpeg"

ap = argparse.ArgumentParser()
ap.add_argument("--limit", type=int, default=0, help="只處理前 N 筆（0=全部）")
ap.add_argument("--no-push", action="store_true", help="只 commit 不 push")
args = ap.parse_args()


def git(*a, check=True):
    r = subprocess.run(["git", "-C", REPO] + list(a), capture_output=True,
                       text=True, encoding="utf-8", errors="ignore")
    if check and r.returncode != 0 and "nothing to commit" not in (r.stdout or ""):
        print(f"  ⚠ git {' '.join(a[:2])}: {(r.stderr or r.stdout)[:200]}")
    return r


# 找出缺語音的物件（依代號排序）
targets = []
for name in sorted(os.listdir(REPO)):
    if not re.fullmatch(r"w\d+", name):
        continue
    d = os.path.join(REPO, name)
    if os.path.isdir(d) and os.path.exists(os.path.join(d, "index.html")) \
            and not os.path.exists(os.path.join(d, "voice.mp3")):
        targets.append(name)
if args.limit:
    targets = targets[:args.limit]

print(f"待補語音：{len(targets)} 筆")
if not targets:
    sys.exit(0)
print(f"範圍：{targets[0]} … {targets[-1]}\n")

# 載入模型（只做一次）
import torch
from voxcpm import VoxCPM
import soundfile as sf

device = "cuda" if torch.cuda.is_available() else "cpu"
print(f"裝置：{device}")
t0 = time.time()
model = VoxCPM.from_pretrained("openbmb/VoxCPM2", load_denoiser=False,
                               device=device, optimize=False)
print(f"模型載入完成，耗時 {time.time()-t0:.1f}s\n")
prompt_text = open(PROMPT_TXT, encoding="utf-8").read().strip()

done, failed, started = 0, [], time.time()
for i, code in enumerate(targets, 1):
    folder = os.path.join(REPO, code)
    try:
        html = open(os.path.join(folder, "index.html"), encoding="utf-8").read()
        m = re.search(r'<span id="narrText"[^>]*>([\s\S]*?)</span>', html)
        if not m or not m.group(1).strip():
            print(f"[{i}/{len(targets)}] {code} ⚠ 找不到講稿，跳過")
            failed.append((code, "no narrText"))
            continue
        narr = m.group(1).strip()

        t1 = time.time()
        wav = model.generate(text=narr, prompt_wav_path=REF_WAV, prompt_text=prompt_text,
                             reference_wav_path=REF_WAV, cfg_value=2.0, inference_timesteps=10)
        sr = model.tts_model.sample_rate
        tmp_wav = os.path.join(folder, "_tmp.wav")
        sf.write(tmp_wav, wav, sr)

        mp3 = os.path.join(folder, "voice.mp3")
        ff = subprocess.run([FFMPEG, "-y", "-i", tmp_wav, "-codec:a", "libmp3lame",
                             "-qscale:a", "2", mp3], capture_output=True)
        os.remove(tmp_wav)
        if ff.returncode != 0 or not os.path.exists(mp3):
            print(f"[{i}/{len(targets)}] {code} ❌ mp3 轉檔失敗")
            failed.append((code, "ffmpeg"))
            continue

        done += 1
        el = time.time() - t1
        avg = (time.time() - started) / done
        eta = avg * (len(targets) - i) / 60
        print(f"[{i}/{len(targets)}] {code} ✅ {el:.0f}s｜{os.path.getsize(mp3)//1024}KB"
              f"｜剩餘約 {eta:.0f} 分")

        if done % COMMIT_EVERY == 0:
            git("add", "--", *[f"{c}/voice.mp3" for c in targets[:i]
                               if os.path.exists(os.path.join(REPO, c, "voice.mp3"))])
            git("commit", "-m", f"feat(voice): 本機 GPU 生成陳慧瑜克隆語音（累計 {done} 筆）")
            print(f"  — 已 commit（{done} 筆）")
    except Exception as e:
        print(f"[{i}/{len(targets)}] {code} ❌ {type(e).__name__}: {e}")
        failed.append((code, str(e)[:80]))

# 收尾
git("add", "--", *[f"{c}/voice.mp3" for c in targets
                   if os.path.exists(os.path.join(REPO, c, "voice.mp3"))])
git("commit", "-m", f"feat(voice): 本機 GPU 生成陳慧瑜克隆語音（本批共 {done} 筆）")
total = (time.time() - started) / 60
print(f"\n完成 {done}/{len(targets)} 筆｜總耗時 {total:.0f} 分鐘｜平均 {total*60/max(done,1):.0f} 秒/筆")
if failed:
    print(f"失敗 {len(failed)} 筆：{failed[:10]}")
if not args.no_push:
    print("推送中…")
    r = git("push", "origin", "main", check=False)
    print("✅ 已推送" if r.returncode == 0 else f"⚠ push 未成功：{(r.stderr or '')[:200]}")
