#!/usr/bin/env python3
"""Validate the HolyToy Shadertoy v1 corpus without compiling its sources."""
from __future__ import annotations

import hashlib
import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ERRORS: list[str] = []
PURE_DISALLOWED = re.compile(r"\b(?:ichannel[0-3]|texture(?:2d|cube|size|lod|proj|gather|grad)?|texelfetch|sampler|imageload|imagestore|mainvr)\b", re.I)


def fail(message: str) -> None:
    ERRORS.append(message)


def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


manifest_path = ROOT / "manifest.jsonl"
rejected_path = ROOT / "rejected.jsonl"
records: list[dict] = []
if not manifest_path.is_file():
    fail("manifest.jsonl is missing")
else:
    for number, line in enumerate(manifest_path.read_text(encoding="utf-8").splitlines(), 1):
        if not line:
            fail(f"manifest line {number} is blank")
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError as exc:
            fail(f"manifest line {number}: {exc}")
            continue
        if not isinstance(item, dict):
            fail(f"manifest line {number} is not an object")
            continue
        records.append(item)

ids: set[str] = set()
referenced_sources: set[str] = set()
for item in records:
    shader_id = item.get("shader_id")
    if not isinstance(shader_id, str) or not shader_id:
        fail("record has no shader_id")
        continue
    if shader_id in ids:
        fail(f"duplicate shader ID {shader_id}")
    ids.add(shader_id)
    metadata_path = ROOT / "shaders" / shader_id / "metadata.json"
    if not metadata_path.is_file():
        fail(f"{shader_id}: metadata.json missing")
    else:
        try:
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            if metadata != item:
                fail(f"{shader_id}: metadata.json is not a semantic manifest mirror")
        except Exception as exc:
            fail(f"{shader_id}: metadata.json invalid: {exc}")
    license_value = item.get("license")
    if not isinstance(license_value, dict) or not license_value.get("identifier") or not license_value.get("evidence_url"):
        fail(f"{shader_id}: explicit license evidence missing")
    project_passes = item.get("passes", [])
    if len(project_passes) != 1 or project_passes[0].get("name") != "Image" or project_passes[0].get("kind") != "image":
        fail(f"{shader_id}: not exactly one Image pass")
    seen_pass_paths: set[str] = set()
    for pass_value in project_passes:
        relative = pass_value.get("path")
        if not isinstance(relative, str) or not relative.startswith(f"shaders/{shader_id}/") or ".." in Path(relative).parts:
            fail(f"{shader_id}: invalid pass path {relative!r}")
            continue
        if relative in seen_pass_paths:
            fail(f"{shader_id}: duplicate pass path {relative}")
        seen_pass_paths.add(relative)
        referenced_sources.add(relative)
        source_path = ROOT / relative
        if not source_path.is_file():
            fail(f"{shader_id}: missing source {relative}")
            continue
        raw = source_path.read_bytes()
        try:
            raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            fail(f"{relative}: invalid UTF-8: {exc}")
        if digest(raw) != pass_value.get("sha256"):
            fail(f"{relative}: SHA-256 mismatch")
        if len(raw) != pass_value.get("bytes"):
            fail(f"{relative}: byte-count mismatch")
        if all(byte < 128 for byte in raw) != pass_value.get("ascii_only"):
            fail(f"{relative}: ASCII flag mismatch")
        lowered = raw.lower()
        for forbidden in (b"<!doctype", b"<html", b"document.cookie", b"set-cookie:", b"authorization: bearer", b"api_key="):
            if forbidden in lowered:
                fail(f"{relative}: prohibited browser/session material marker {forbidden!r}")
        forbidden_auxiliary = sorted(set(match.group(0) for match in PURE_DISALLOWED.finditer(raw.decode("utf-8-sig"))))
        if forbidden_auxiliary:
            fail(f"{relative}: prohibited auxiliary texture/channel operation(s): {forbidden_auxiliary}")
        channels: set[int] = set()
        if pass_value.get("inputs"):
            fail(f"{relative}: pure corpus pass must not declare inputs")
        for input_value in pass_value.get("inputs", []):
            channel = input_value.get("channel")
            if not isinstance(channel, int) or channel not in range(4):
                fail(f"{relative}: invalid channel {channel!r}")
            elif channel in channels:
                fail(f"{relative}: duplicate channel {channel}")
            channels.add(channel)
            if not input_value.get("type"):
                fail(f"{relative}: input channel {channel} has no type")

actual_sources = {str(path.relative_to(ROOT)).replace("\\", "/") for path in (ROOT / "shaders").glob("*/*.glsl")}
if actual_sources != referenced_sources:
    fail(f"saved source set differs from manifest paths: missing={sorted(referenced_sources - actual_sources)}, extra={sorted(actual_sources - referenced_sources)}")

rejected_ids: set[str] = set()
if not rejected_path.is_file():
    fail("rejected.jsonl is missing")
else:
    for number, line in enumerate(rejected_path.read_text(encoding="utf-8").splitlines(), 1):
        if not line:
            fail(f"rejected line {number} is blank")
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError as exc:
            fail(f"rejected line {number}: {exc}")
            continue
        shader_id = item.get("shader_id")
        if not shader_id or shader_id in rejected_ids:
            fail(f"invalid or duplicate rejected ID on line {number}")
        rejected_ids.add(shader_id)
        for required in ("url", "rejection_reason", "license_status", "retrieval_error"):
            if required not in item:
                fail(f"rejected line {number} missing {required}")
if ids & rejected_ids:
    fail(f"accepted/rejected ID overlap: {sorted(ids & rejected_ids)}")

allowed_root_files = {"README.md", "manifest.jsonl", "rejected.jsonl", "validate.py"}
for path in ROOT.rglob("*"):
    if not path.is_file():
        continue
    relative = str(path.relative_to(ROOT)).replace("\\", "/")
    if relative in allowed_root_files:
        continue
    if re.fullmatch(r"shaders/[^/]+/(metadata\.json|[a-z0-9-]+\.glsl)", relative):
        continue
    fail(f"unexpected corpus file {relative}")

if ERRORS:
    print("VALIDATION FAILED")
    print("\n".join(f"- {error}" for error in ERRORS))
    sys.exit(1)

domain_counts = Counter(item["coverage"]["visual_domain"] for item in records)
stratum_counts = Counter(item["coverage"]["primary_stratum"] for item in records)
license_counts = Counter(item["license"]["identifier"] for item in records)
unusual = sum(bool(item["coverage"]["unusual_features"]) for item in records)
non_ascii = sum(not pass_value["ascii_only"] for item in records for pass_value in item["passes"])
print(f"accepted={len(records)}")
print(f"rejected={len(rejected_ids)}")
print("domains=" + json.dumps(dict(sorted(domain_counts.items())), sort_keys=True))
print("primary_strata=" + json.dumps(dict(sorted(stratum_counts.items())), sort_keys=True))
print(f"unusual_overlap={unusual}")
print("licenses=" + json.dumps(dict(sorted(license_counts.items())), sort_keys=True))
print(f"non_ascii_passes={non_ascii}")
print("manifest_sha256=" + digest(manifest_path.read_bytes()))
