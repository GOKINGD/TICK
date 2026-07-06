#!/usr/bin/env python3
import json
import os
import shutil
import sys
import tempfile
import urllib.request
import zipfile

if len(sys.argv) < 3:
    raise SystemExit("Usage: preview_skill.py <skill_name> <download_url>")

skill_name = sys.argv[1]
download_url = sys.argv[2]
skills_dir = os.environ.get("TICK_SKILLS_DIR") or os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

def read_frontmatter(text):
    result = {}
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return result, text
    body_start = 0
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            body_start = i + 1
            break
        if ":" in line:
            key, value = line.split(":", 1)
            result[key.strip()] = value.strip().strip("'\"")
    return result, "\n".join(lines[body_start:])

temp_dir = tempfile.mkdtemp(prefix="tick-skill-preview-")
try:
    zip_path = os.path.join(temp_dir, "skill.zip")
    urllib.request.urlretrieve(download_url, zip_path)
    extract_dir = os.path.join(temp_dir, "extract")
    os.makedirs(extract_dir, exist_ok=True)
    with zipfile.ZipFile(zip_path) as archive:
        archive.extractall(extract_dir)

    skill_md = None
    for root, _, files in os.walk(extract_dir):
        if "SKILL.md" in files:
            skill_md = os.path.join(root, "SKILL.md")
            break
    if not skill_md:
        raise SystemExit("No SKILL.md found in archive.")

    with open(skill_md, "r", encoding="utf-8") as handle:
        text = handle.read()
    frontmatter, body = read_frontmatter(text)
    overview = body.strip().replace("\r", "")[:500]
    print(json.dumps({
        "environment": "TICK",
        "install_path": os.path.join(skills_dir, frontmatter.get("name") or skill_name),
        "name": frontmatter.get("name") or skill_name,
        "description": frontmatter.get("description") or "",
        "overview": overview
    }, ensure_ascii=False))
finally:
    shutil.rmtree(temp_dir, ignore_errors=True)