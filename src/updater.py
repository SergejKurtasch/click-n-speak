"""
Check for app updates via GitHub Releases API.
Returns UpdateInfo when a newer version is available; never opens a browser.
"""

import json
import logging
import plistlib
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

from .utils import log_error, log_info

logger = logging.getLogger(__name__)

GITHUB_REPO = "SergejKurtasch/click-n-speak"
RELEASES_API_URL = f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest"
REQUEST_TIMEOUT = 10


@dataclass
class UpdateInfo:
    tag_name: str           # e.g. "v1.2.3"
    version_display: str    # same, always starts with "v"
    html_url: str           # GitHub release page
    dmg_url: Optional[str]  # direct download URL for .dmg asset, or None
    dmg_size: int           # bytes (0 if unknown)

    @classmethod
    def staged(cls, version: str) -> "UpdateInfo":
        """Synthetic UpdateInfo for a locally staged update (no network needed)."""
        v = version if version.startswith("v") else f"v{version}"
        return cls(
            tag_name=v,
            version_display=v,
            html_url=f"https://github.com/{GITHUB_REPO}/releases",
            dmg_url=None,
            dmg_size=0,
        )


def _parse_version(version_str: str) -> tuple[int, ...]:
    """Normalize version string to comparable tuple (e.g. 'v0.2.0' -> (0, 2, 0))."""
    cleaned = re.sub(r"^v", "", version_str.strip()).strip()
    parts = []
    for part in re.split(r"[.\-]", cleaned):
        part = re.sub(r"[^0-9].*$", "", part)
        try:
            parts.append(int(part) if part else 0)
        except ValueError:
            parts.append(0)
    return tuple(parts) if parts else (0,)


def get_current_version() -> Optional[str]:
    """Return current app version from Info.plist (.app) or pyproject.toml (dev)."""
    from .utils import _get_app_bundle
    app_bundle = _get_app_bundle()
    if app_bundle:
        plist_path = Path(app_bundle) / "Contents" / "Info.plist"
        if plist_path.exists():
            try:
                with open(plist_path, "rb") as f:
                    plist = plistlib.load(f)
                return (
                    plist.get("CFBundleShortVersionString")
                    or plist.get("CFBundleVersion")
                    or None
                )
            except (OSError, plistlib.InvalidFileException) as e:
                log_error(f"Could not read version from plist: {e}")
                return None

    root = Path(__file__).resolve().parent.parent
    pyproject = root / "pyproject.toml"
    if pyproject.exists():
        try:
            content = pyproject.read_text(encoding="utf-8")
            match = re.search(r'version\s*=\s*["\']([^"\']+)["\']', content)
            if match:
                return match.group(1).strip()
        except OSError as e:
            log_error(f"Could not read pyproject.toml: {e}")
    return None


def fetch_latest_release() -> Optional[dict]:
    """Fetch latest release from GitHub API. Returns None on error."""
    try:
        req = Request(RELEASES_API_URL, headers={"Accept": "application/vnd.github.v3+json"})
        with urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return data
    except (URLError, HTTPError, OSError, json.JSONDecodeError) as e:
        logger.debug("Update check failed: %s", e)
        return None


def _find_dmg_asset(assets: list) -> tuple[Optional[str], int]:
    """Return (download_url, size) for the first .dmg asset, or (None, 0)."""
    for asset in assets:
        name = asset.get("name", "")
        if name.lower().endswith(".dmg"):
            return asset.get("browser_download_url"), asset.get("size", 0)
    return None, 0


def check_for_update() -> Optional[UpdateInfo]:
    """Check if a newer version is available. Returns UpdateInfo or None.

    Never opens a browser or sends a notification — callers decide what to do.
    """
    current = get_current_version()
    if not current:
        return None

    release = fetch_latest_release()
    if not release:
        return None

    tag_name = release.get("tag_name") or ""
    html_url = release.get("html_url") or f"https://github.com/{GITHUB_REPO}/releases"
    assets = release.get("assets") or []

    remote_version = _parse_version(tag_name)
    current_version = _parse_version(current)

    if remote_version <= current_version:
        return None

    version_display = tag_name if tag_name.startswith("v") else f"v{tag_name}"
    dmg_url, dmg_size = _find_dmg_asset(assets)

    log_info(f"Update available: {version_display} (current: {current}, dmg: {'yes' if dmg_url else 'no'})")
    return UpdateInfo(
        tag_name=tag_name,
        version_display=version_display,
        html_url=html_url,
        dmg_url=dmg_url,
        dmg_size=dmg_size,
    )
