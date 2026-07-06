#!/usr/bin/env python3
import json
import os
import re
import shutil
import sys
import tempfile
import urllib.request
import zipfile

root = os.environ.get("TICK_SKILLS_DIR") or os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

def clean_name(value):
    value = (value or "custom-skill").lower()
    parts = re.findall(r"[a-z0-9]+", value)
    return "-".join(parts) or "custom-skill"

def install_generated(payload):
    name = clean_name(payload.get("name"))
    description = (payload.get("description") or "Reusable TICK skill.").replace("\n", " ")
    instruction = payload.get("instruction") or "Follow the user's request."
    target = os.path.join(root, name)
    os.makedirs(target, exist_ok=True)
    with open(os.path.join(target, "SKILL.md"), "w", encoding="utf-8") as f:
        f.write("---\n")
        f.write(f"name: {name}\n")
        f.write(f"description: {description}\n")
        f.write("---\n\n")
        f.write(instruction.strip() + "\n")
    return {"installed": True, "name": name, "path": target}

def find_skill_dir(path):
    if os.path.exists(os.path.join(path, "SKILL.md")):
        return path
    for entry in os.listdir(path):
        candidate = os.path.join(path, entry)
        if os.path.isdir(candidate) and os.path.exists(os.path.join(candidate, "SKILL.md")):
            return candidate
    raise SystemExit("No SKILL.md found in archive.")

def install_zip(skill_name, download_url):
    temp_dir = tempfile.mkdtemp(prefix="tick-skill-install-")
    try:
        zip_path = os.path.join(temp_dir, "skill.zip")
        urllib.request.urlretrieve(download_url, zip_path)
        extract_dir = os.path.join(temp_dir, "extract")
        os.makedirs(extract_dir, exist_ok=True)
        with zipfile.ZipFile(zip_path) as archive:
            archive.extractall(extract_dir)
        source = find_skill_dir(extract_dir)
        target = os.path.join(root, clean_name(skill_name))
        if os.path.exists(target):
            shutil.rmtree(target)
        shutil.copytree(source, target)
        return {"installed": True, "name": clean_name(skill_name), "path": target}
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)

if len(sys.argv) >= 3:
    result = install_zip(sys.argv[1], sys.argv[2])
else:
    payload = json.load(sys.stdin)
    result = install_generated(payload)

print(json.dumps(result, ensure_ascii=False))