#!/usr/bin/env python3
"""
sync_voices.py - 自動化監控與上傳「法拍女王 陳慧瑜」真人克隆語音
邏輯：
1. 讀取並檢查本地 .env 的 GITHUB_TOKEN。
2. 透過 GitHub API 取得 taiwan2531-web/Queen-of-Auctions 倉庫內容。
3. 尋找所有物件資料夾，若有 index.html 但沒有 voice.mp3，則：
   a. 下載 index.html 並擷取 {{NARRATION}} 文字。
   b. 用「法拍女王 陳慧瑜」的聲音執行 clone.py 生成語音。
   c. 將產出的 wav 轉成 mp3。
   d. 上傳 mp3 到 GitHub 倉庫的對應目錄。
"""

import os
import re
import sys
import json
import base64
import subprocess
import requests
import io

# 強制標準輸出與標準錯誤輸出設定為 UTF-8
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8')

REPO_DIR = os.path.dirname(os.path.abspath(__file__))
OWNER = "taiwan2531-web"
REPO = "Queen-of-Auctions"
VOICE_NAME = "法拍女王 陳慧瑜"

# 載入 .env 變數
def load_env():
    # 優先從環境變數讀取 (支援 GitHub Actions)
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if token:
        return token
    # 其次從本地 .env 讀取
    env_path = os.path.join(REPO_DIR, ".env")
    if os.path.exists(env_path):
        with open(env_path, "r", encoding="utf-8") as f:
            for line in f:
                if line.strip().startswith("GITHUB_TOKEN="):
                    token = line.strip().split("=", 1)[1].strip()
    return token

def get_headers(token):
    headers = {
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "VoxCPM-Voice-Cloner-SyncAgent"
    }
    if token:
        headers["Authorization"] = f"token {token}"
    return headers

def list_repo_contents(path="", token=""):
    url = f"https://api.github.com/repos/{OWNER}/{REPO}/contents/{path}"
    r = requests.get(url, headers=get_headers(token))
    if r.status_code == 200:
        return r.json()
    return []

def download_file(download_url, token=""):
    r = requests.get(download_url, headers=get_headers(token))
    if r.status_code == 200:
        return r.text
    return ""

def upload_file(path, content_b64, message, sha=None, token=""):
    url = f"https://api.github.com/repos/{OWNER}/{REPO}/contents/{path}"
    data = {
        "message": message,
        "content": content_b64
    }
    if sha:
        data["sha"] = sha
        
    r = requests.put(url, headers=get_headers(token), json=data)
    if r.status_code in [200, 201]:
        print(f"  成功上傳 {path} 到 GitHub！")
        return True
    else:
        print(f"  上傳 {path} 失敗：{r.status_code} - {r.text}")
        return False

def main():
    token = load_env()
    if not token:
        print("⚠️ 警告：未在專案 .env 檔案中找到 GITHUB_TOKEN，寫入權限受限！")
        print("請建立一個 .env 檔案，並寫入：GITHUB_TOKEN=您的Token")
        print("（您可以從 https://github.com/settings/tokens 申請 classic token，需具備 repo 權限）")
        sys.exit(1)

    print("🔍 正在從 GitHub 讀取倉庫物件清單...")
    contents = list_repo_contents("", token)
    
    # 篩選出物件資料夾 (排除了根目錄的特別檔案如 template.html, index.html 等)
    ignored_items = {"patches", "voices", "output", "texts", "obsidian"}
    folders = []
    for item in contents:
        if item["type"] == "dir" and item["name"] not in ignored_items and not item["name"].startswith("."):
            folders.append(item["name"])
            
    print(f"找到的物件資料夾：{folders}")

    for folder in folders:
        print(f"\n📂 正在處理物件「{folder}」...")
        folder_contents = list_repo_contents(folder, token)
        
        has_index = False
        has_mp3 = False
        index_download_url = ""
        existing_mp3_sha = None
        
        for file in folder_contents:
            if file["name"] == "index.html":
                has_index = True
                index_download_url = file["download_url"]
            elif file["name"] == "voice.mp3":
                has_mp3 = True
                existing_mp3_sha = file["sha"]
                
        if not has_index:
            print("  沒有 index.html，跳過。")
            continue
            
        if has_mp3:
            print("  已存在 voice.mp3，無需升級。")
            continue
            
        print("  發現需要升級的物件！正在下載 index.html 提取說話文字...")
        html_content = download_file(index_download_url, token)
        if not html_content:
            print("  下載 index.html 失敗！")
            continue
            
        # 擷取 <span id="narrText" hidden>{{NARRATION}}</span> 中的內容
        # 範本：<span id="narrText" hidden>哈囉大家好，我是法拍女王陳慧瑜！...</span>
        match = re.search(r'<span id="narrText"[^>]*>([\s\S]*?)</span>', html_content)
        if not match:
            print("  在 HTML 中找不到 <span id='narrText'>，跳過。")
            continue
            
        narration_text = match.group(1).strip()
        print(f"  說話文字內容：{narration_text}")
        
        # 建立臨時輸出目錄
        temp_wav = os.path.join(REPO_DIR, "output", f"temp_{folder}.wav")
        temp_mp3 = os.path.join(REPO_DIR, "output", f"temp_{folder}.mp3")
        os.makedirs(os.path.dirname(temp_wav), exist_ok=True)
        
        # 執行 clone.py 生成語音
        print("  正在呼叫 VoxCPM2 生成克隆語音...")
        venv_python = sys.executable
        clone_script = os.path.join(REPO_DIR, "clone.py")
        
        # 使用 subprocess 呼叫
        run_res = subprocess.run([
            venv_python, clone_script,
            narration_text,
            "--voice", VOICE_NAME,
            "--output", temp_wav
        ], capture_output=True, text=True, encoding="utf-8")
        
        if run_res.returncode != 0 or not os.path.exists(temp_wav):
            print(f"  語音生成失敗！錯誤：{run_res.stderr}")
            continue
            
        # 使用 ffmpeg 轉成 mp3
        print("  正在使用 ffmpeg 將 WAV 轉成 MP3 格式...")
        ffmpeg_res = subprocess.run([
            "ffmpeg", "-y", "-i", temp_wav,
            "-codec:a", "libmp3lame",
            "-qscale:a", "2",
            temp_mp3
        ], capture_output=True)
        
        if ffmpeg_res.returncode != 0 or not os.path.exists(temp_mp3):
            print(f"  MP3 轉換失敗！錯誤：{ffmpeg_res.stderr.decode('utf-8', errors='ignore')}")
            # 清理 WAV
            if os.path.exists(temp_wav): os.remove(temp_wav)
            continue
            
        # 將 MP3 轉為 Base64
        with open(temp_mp3, "rb") as f:
            mp3_data = f.read()
            mp3_b64 = base64.b64encode(mp3_data).decode("utf-8")
            
        # 上傳到 GitHub
        github_path = f"{folder}/voice.mp3"
        print(f"  正在上傳 {github_path} 到 GitHub 倉庫...")
        upload_file(github_path, mp3_b64, f"feat({folder}): 升級陳慧瑜克隆語音 voice.mp3", existing_mp3_sha, token)
        
        # 清理臨時檔案
        if os.path.exists(temp_wav): os.remove(temp_wav)
        if os.path.exists(temp_mp3): os.remove(temp_mp3)
        print(f"  物件「{folder}」克隆語音已完成並上傳！")

if __name__ == "__main__":
    main()
