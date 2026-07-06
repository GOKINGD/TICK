#!/usr/bin/env python3
import json
import os
import sys
import urllib.parse
import urllib.request

if len(sys.argv) < 2:
    raise SystemExit("Usage: get_download_url.py <skill_name>")

skill_name = sys.argv[1]
endpoint = os.environ.get("TICK_SKILL_REGISTRY_URL", "").strip()
token = os.environ.get("TICK_SKILL_REGISTRY_TOKEN", "").strip()

if not endpoint:
    print(json.dumps({
        "error": "skill_registry_not_configured",
        "message": "当前没有配置远端技能仓库，无法获取下载链接。可以通过TICK Tools设置上传skill zip，或配置TICK_SKILL_REGISTRY_URL后再试。",
        "skill": skill_name
    }, ensure_ascii=False))
    raise SystemExit(0)

url = endpoint.rstrip("/") + "/" + urllib.parse.quote(skill_name)
request = urllib.request.Request(url, headers={"Accept": "application/json"})
if token:
    request.add_header("Authorization", "Bearer " + token)

try:
    with urllib.request.urlopen(request, timeout=15) as response:
        data = json.loads(response.read().decode("utf-8"))
except Exception as exc:
    print(json.dumps({
        "error": "skill_registry_fetch_failed",
        "message": "获取skill下载链接失败。",
        "detail": str(exc),
        "skill": skill_name
    }, ensure_ascii=False))
    raise SystemExit(0)

download_url = ""
if isinstance(data, dict):
    download_url = str(data.get("download_url") or data.get("url") or data.get("zip_url") or "").strip()
if not download_url:
    print(json.dumps({
        "error": "skill_download_url_missing",
        "message": "远端平台没有返回该skill的下载链接。",
        "skill": skill_name
    }, ensure_ascii=False))
    raise SystemExit(0)
print(download_url)