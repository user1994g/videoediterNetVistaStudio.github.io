from __future__ import annotations

import hashlib
import json
import platform
import shutil
import tempfile
import urllib.request
from dataclasses import dataclass
from functools import cmp_to_key
from pathlib import Path
from typing import Callable


RELEASES_URL = "https://api.github.com/repos/user1994g/videoediterNetVistaStudio.github.io/releases?per_page=30"


@dataclass(frozen=True)
class ReleaseAsset:
    name: str
    download_url: str
    size: int = 0
    digest: str | None = None


@dataclass(frozen=True)
class AvailableUpdate:
    tag: str
    name: str
    page_url: str
    prerelease: bool
    asset: ReleaseAsset


def compare_versions(left: str, right: str) -> int:
    """Compare the release tags used by NetVista Studio (including betas)."""
    left_core, left_pre = _version_parts(left)
    right_core, right_pre = _version_parts(right)
    count = max(len(left_core), len(right_core))
    for index in range(count):
        lhs = left_core[index] if index < len(left_core) else 0
        rhs = right_core[index] if index < len(right_core) else 0
        if lhs != rhs:
            return 1 if lhs > rhs else -1
    if left_pre is None and right_pre is None:
        return 0
    if left_pre is None:
        return 1
    if right_pre is None:
        return -1
    for index in range(max(len(left_pre), len(right_pre))):
        if index >= len(left_pre):
            return -1
        if index >= len(right_pre):
            return 1
        lhs, rhs = left_pre[index], right_pre[index]
        if lhs == rhs:
            continue
        if lhs.isdigit() and rhs.isdigit():
            return 1 if int(lhs) > int(rhs) else -1
        if lhs.isdigit() != rhs.isdigit():
            return -1 if lhs.isdigit() else 1
        return 1 if lhs.lower() > rhs.lower() else -1
    return 0


def select_update(releases: list[dict], current_tag: str, system_name: str | None = None) -> AvailableUpdate | None:
    system_name = system_name or platform.system()
    candidates: list[AvailableUpdate] = []
    for release in releases:
        tag = str(release.get("tag_name", ""))
        if release.get("draft") or compare_versions(tag, current_tag) <= 0:
            continue
        asset_data = next((item for item in release.get("assets", [])
                           if asset_matches(str(item.get("name", "")), system_name)), None)
        if not asset_data:
            continue
        asset = ReleaseAsset(str(asset_data["name"]), str(asset_data["browser_download_url"]),
                             int(asset_data.get("size", 0)), asset_data.get("digest"))
        candidates.append(AvailableUpdate(tag, str(release.get("name") or tag),
                                          str(release.get("html_url", "")),
                                          bool(release.get("prerelease")), asset))
    if not candidates:
        return None
    return sorted(candidates, key=cmp_to_key(lambda a, b: compare_versions(a.tag, b.tag)))[-1]


def asset_matches(name: str, system_name: str) -> bool:
    lower = name.lower()
    system = system_name.lower()
    if system in {"darwin", "macos"}:
        return "-macos-" in lower and lower.endswith(".zip")
    if system == "windows":
        return "-windows-" in lower and lower.endswith(".zip")
    if system == "linux":
        return "-linux-" in lower and (lower.endswith(".tar.gz") or lower.endswith(".zip"))
    return False


def check_for_update(current_tag: str, system_name: str, emit: Callable[[float, str], None]) -> AvailableUpdate | None:
    emit(0.1, "Checking GitHub releases")
    request = urllib.request.Request(RELEASES_URL, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": f"NetVistaStudio/{current_tag}",
    })
    with urllib.request.urlopen(request, timeout=20) as response:
        releases = json.loads(response.read().decode("utf-8"))
    emit(1.0, "Update check complete")
    return select_update(releases, current_tag, system_name)


def download_update(update: AvailableUpdate, emit: Callable[[float, str], None]) -> str:
    downloads = Path.home() / "Downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    destination = _unique_destination(downloads, update.asset.name)
    partial: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".netvista-update-", suffix=".part", dir=downloads, delete=False) as output:
            partial = Path(output.name)
            request = urllib.request.Request(update.asset.download_url,
                                             headers={"User-Agent": f"NetVistaStudio/{update.tag}"})
            with urllib.request.urlopen(request, timeout=120) as response:
                expected = update.asset.size or int(response.headers.get("Content-Length", "0") or 0)
                received = 0
                digest = hashlib.sha256()
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    output.write(chunk)
                    digest.update(chunk)
                    received += len(chunk)
                    emit(min(0.99, received / expected) if expected else 0.5,
                         f"Downloading {update.asset.name}")
        actual_size = partial.stat().st_size
        if update.asset.size and actual_size != update.asset.size:
            raise RuntimeError(f"Incomplete update: expected {update.asset.size} bytes, received {actual_size}")
        if not update.asset.digest or not update.asset.digest.lower().startswith("sha256:"):
            raise RuntimeError("GitHub did not publish a SHA-256 safety checksum for this update")
        expected_hash = update.asset.digest.split(":", 1)[1].lower()
        actual_hash = digest.hexdigest().lower()
        if len(expected_hash) != 64 or expected_hash != actual_hash:
            raise RuntimeError("The downloaded update did not pass its SHA-256 safety check")
        shutil.move(str(partial), destination)
        partial = None
        emit(1.0, "Update downloaded and verified")
        return str(destination)
    finally:
        if partial and partial.exists():
            partial.unlink()


def _version_parts(raw: str) -> tuple[list[int], list[str] | None]:
    cleaned = raw.strip().lstrip("vV")
    core_text, separator, prerelease = cleaned.partition("-")
    core = [int(item) if item.isdigit() else 0 for item in core_text.split(".")]
    return core, prerelease.split(".") if separator and prerelease else None


def _unique_destination(directory: Path, name: str) -> Path:
    first = directory / name
    if not first.exists():
        return first
    if name.lower().endswith(".tar.gz"):
        stem, extension = name[:-7], ".tar.gz"
    else:
        source = Path(name)
        stem, extension = source.stem, source.suffix
    for number in range(2, 1000):
        candidate = directory / f"{stem} {number}{extension}"
        if not candidate.exists():
            return candidate
    raise RuntimeError("Too many copies of this update are already in Downloads")
