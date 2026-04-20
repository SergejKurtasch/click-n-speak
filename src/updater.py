"""
Check for app updates via GitHub Releases API.
Compares current version with latest release and notifies user with download link.
"""

import json
import logging
import os
import plistlib
import re
import subprocess
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError
from typing import Optional

from .utils import log_error, log_info, send_notification

logger = logging.getLogger(__name__)

GITHUB_REPO = "SergejKurtasch/click-n-speak"
RELEASES_API_URL = f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest"
REQUEST_TIMEOUT = 10


def _parse_version(version_str: str) -> tuple[int, ...]:
    """Normalize version string to comparable tuple (e.g. '0.2.0' or 'v0.2.0' -> (0, 2, 0))."""
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
    """
    Return current app version.
    When run from .app: read from Info.plist. Otherwise read from pyproject.toml.
    """
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

    # Development: read from pyproject.toml (project root = parent of src/)
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


def check_for_update(open_url_if_new: bool = True) -> bool:
    """
    Check if a newer version is available. If so, notify user and optionally open release page.
    Returns True if an update is available and user was notified, False otherwise.
    """
    current = get_current_version()
    if not current:
        return False

    release = fetch_latest_release()
    if not release:
        return False

    tag_name = release.get("tag_name") or ""
    html_url = release.get("html_url") or f"https://github.com/{GITHUB_REPO}/releases"
    remote_version = _parse_version(tag_name)
    current_version = _parse_version(current)

    if remote_version <= current_version:
        return False

    version_display = tag_name if tag_name.startswith("v") else f"v{tag_name}"
    log_info(f"Update available: {version_display} (current: {current})")
    send_notification(
        "Click-n-speak",
        "Update available",
        f"Version {version_display} is available. Click to open download page.",
    )
    if open_url_if_new:
        try:
            subprocess.run(["open", html_url], check=True)
        except (subprocess.CalledProcessError, OSError) as e:
            log_error(f"Could not open release URL: {e}")
    return True
