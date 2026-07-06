#!/usr/bin/env python3
import json
import os
import sys
import urllib.request

endpoint = os.environ.get("TICK_SKILL_REGISTRY_URL", "").strip()
token = os.environ.get("TICK_SKILL_REGISTRY_TOKEN", "").strip()

if not endpoint:
    print(json.dumps({
        "error": "skill_registry_not_configured",
        "message": "当前没有配置远端技能仓库，无法自动推荐或安装新skill。可以通过TICK Tools设置上传skill zip，或配置TICK_SKILL_REGISTRY_URL后再试。",
        "skills": []
    }, ensure_ascii=False))
    raise SystemExit(0)

request = urllib.request.Request(endpoint, headers={"Accept": "application/json"})
if token:
    request.add_header("Authorization", "Bearer " + token)

try:
    with urllib.request.urlopen(request, timeout=15) as response:
        data = json.loads(response.read().decode("utf-8"))
except Exception as exc:
    print(json.dumps({
        "error": "skill_registry_fetch_failed",
        "message": "获取远端技能列表失败。",
        "detail": str(exc)
    }, ensure_ascii=False))
    raise SystemExit(0)

if isinstance(data, dict):
    data = data.get("skills") or data.get("data") or []
if not isinstance(data, list):
    print(json.dumps({
        "error": "skill_registry_invalid_response",
        "message": "远端技能平台返回格式不正确。",
        "skills": []
    }, ensure_ascii=False))
    raise SystemExit(0)

normalized = []
for item in data:
    if not isinstance(item, dict):
        continue
    name = str(item.get("name") or item.get("id") or "").strip()
    description = str(item.get("description") or "").strip()
    download_url = str(item.get("download_url") or item.get("url") or item.get("zip_url") or "").strip()
    if name and description:
        normalized.append({
            "name": name,
            "description": description,
            "download_url": download_url
        })
print(json.dumps(normalized, ensure_ascii=False))