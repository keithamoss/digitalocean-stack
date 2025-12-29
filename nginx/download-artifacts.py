#!/usr/bin/env python3
"""Download latest Staging CI/CD workflow artifacts into nginx/content."""

from __future__ import annotations

import json
import os
import sys
import tarfile
import shutil
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener
from zipfile import BadZipFile, ZipFile

API_URL = "https://api.github.com"
GITHUB_REPO = "keithamoss/demsausage"
WORKFLOW_FILE = "staging_cicd.yml"
WORKFLOW_LABEL = "Staging CI/CD"
USER_AGENT = "demsausage-artifact-downloader/1.0"
ACCEPT_JSON = "application/vnd.github+json"
ACCEPT_BINARY = "*/*"
GITHUB_API_VERSION = "2022-11-28"
GITHUB_API_HOST = urlparse(API_URL).hostname or "api.github.com"
REDIRECT_STATUS = {301, 302, 303, 307, 308}
MAX_REDIRECTS = 5
AUTH_REDIRECT_HOST_SUFFIXES = (
    "actions.githubusercontent.com",
    "visualstudio.com",
)
NESTED_TAR_SUFFIXES = (".tar", ".tar.gz", ".tgz")


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    sys.exit(1)


class NoRedirectHandler(HTTPRedirectHandler):
    """Prevent urllib from auto-following redirects so we can manage headers."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _validate_archive_members(members: list[str], target_dir: Path) -> list[Path]:
    dest_root = str(target_dir.resolve())
    validated = []
    for member in members:
        candidate = (target_dir / member).resolve()
        if os.path.commonpath([dest_root, str(candidate)]) != dest_root:
            fail("Archive extraction attempted to write outside destination directory.")
        validated.append(candidate)
    return validated


def _is_nested_tarball(path: Path) -> bool:
    lowered = path.name.lower()
    return any(lowered.endswith(suffix) for suffix in NESTED_TAR_SUFFIXES)


def _safe_extract_tar(tar_file: tarfile.TarFile, target_dir: Path) -> None:
    dest_root = str(target_dir.resolve())
    for member in tar_file.getmembers():
        member_path = (target_dir / member.name).resolve()
        if os.path.commonpath([dest_root, str(member_path)]) != dest_root:
            fail("Nested tarball attempted to write outside destination directory.")
    tar_file.extractall(target_dir, filter="data")


def _extract_nested_archives(paths: list[Path], target_dir: Path) -> None:
    for path in paths:
        if not path.exists() or path.is_dir() or not _is_nested_tarball(path):
            continue
        rel_display = os.path.relpath(path, target_dir)
        print(f"Unpacking nested archive '{rel_display}'")
        try:
            with tarfile.open(path) as nested:
                _safe_extract_tar(nested, target_dir)
        except (tarfile.TarError, OSError) as exc:
            fail(f"Failed to extract nested archive '{rel_display}': {exc}")
        else:
            path.unlink()


def _should_send_auth(hostname: str) -> bool:
    if not hostname:
        return False
    return hostname == GITHUB_API_HOST or hostname.endswith(AUTH_REDIRECT_HOST_SUFFIXES)


def _should_send_version_header(hostname: str) -> bool:
    return bool(hostname and hostname == GITHUB_API_HOST)


def github_request(
    url: str,
    token: str | None,
    accept: str = ACCEPT_JSON,
    binary: bool = False,
) -> str | bytes:
    base_headers = {
        "Accept": accept,
        "User-Agent": USER_AGENT,
    }
    auth_header = f"Bearer {token}" if token else None
    opener = build_opener(NoRedirectHandler())
    current_url = url
    redirects_followed = 0

    while True:
        hostname = urlparse(current_url).hostname or ""
        headers = base_headers.copy()
        if _should_send_version_header(hostname):
            headers["X-GitHub-Api-Version"] = GITHUB_API_VERSION
        if auth_header and _should_send_auth(hostname):
            headers["Authorization"] = auth_header

        request = Request(current_url, headers=headers)
        try:
            with opener.open(request) as response:
                data = response.read()
        except HTTPError as exc:
            if exc.code in REDIRECT_STATUS:
                location = exc.headers.get("Location")
                if not location:
                    fail(f"Redirect missing Location header while requesting {current_url}.")
                redirects_followed += 1
                if redirects_followed > MAX_REDIRECTS:
                    fail(f"Too many redirects while requesting {url}.")
                current_url = urljoin(current_url, location)
                continue
            fail(f"GitHub API request failed ({exc.code} {exc.reason}) for {url}.")
        except URLError as exc:
            fail(f"GitHub API request failed ({exc.reason}) for {url}.")

        return data if binary else data.decode("utf-8")


def latest_successful_run_id(token: str | None) -> int:
    url = (
        f"{API_URL}/repos/{GITHUB_REPO}/actions/workflows/{WORKFLOW_FILE}/"
        "runs?per_page=1&status=success"
    )
    payload = json.loads(github_request(url, token))
    runs = payload.get("workflow_runs") or []
    if not runs:
        fail(f"No successful {WORKFLOW_LABEL} workflow runs were found.")

    try:
        return int(runs[0]["id"])
    except (KeyError, TypeError, ValueError):
        fail("Unable to parse workflow run id.")
    return 0  # Unreachable but satisfies the type checker.


def workflow_artifacts(run_id: int, token: str | None) -> list[dict]:
    url = f"{API_URL}/repos/{GITHUB_REPO}/actions/runs/{run_id}/artifacts"
    payload = json.loads(github_request(url, token))
    artifacts = payload.get("artifacts") or []
    if not artifacts:
        fail(f"No artifacts found for workflow run {run_id}.")
    return artifacts


def download_artifact(artifact: dict, dest_dir: Path, token: str | None) -> None:
    name = artifact.get("name")
    download_url = artifact.get("archive_download_url")
    expired = artifact.get("expired", False)
    if not name or not download_url:
        fail("Artifact metadata missing name or download URL.")
    if expired:
        fail(f"Artifact '{name}' has expired and cannot be downloaded.")

    dest_root = str(dest_dir.resolve())
    artifact_dir = (dest_dir / name).resolve()
    if os.path.commonpath([dest_root, str(artifact_dir)]) != dest_root:
        fail("Artifact directory resolves outside of destination root.")

    if artifact_dir.exists():
        if not artifact_dir.is_dir():
            fail(f"Artifact destination '{artifact_dir}' exists and is not a directory.")
        rel_display = os.path.relpath(artifact_dir, dest_dir)
        print(f"Removing existing artifact directory '{rel_display}'")
        shutil.rmtree(artifact_dir)

    artifact_dir.mkdir(parents=True, exist_ok=True)
    destination = artifact_dir / f"{name}.zip"
    print(f"Downloading artifact '{name}' -> {destination}")
    binary_data = github_request(download_url, token, accept=ACCEPT_BINARY, binary=True)
    destination.write_bytes(binary_data)

    print(f"Extracting artifact '{name}'")
    try:
        with ZipFile(destination) as archive:
            members = _validate_archive_members(archive.namelist(), artifact_dir)
            archive.extractall(artifact_dir)
    except BadZipFile:
        fail(f"Artifact '{name}' is not a valid ZIP archive.")
    else:
        _extract_nested_archives(members, artifact_dir)
        destination.unlink(missing_ok=True)


def ensure_tools_available() -> None:
    if sys.version_info < (3, 8):
        fail("Python 3.8+ is required to download artifacts.")


def resolve_paths() -> tuple[Path, Path]:
    script_path = Path(__file__).resolve()
    repo_root = script_path.parent.parent
    content_dir = repo_root / "nginx" / "content"
    content_dir.mkdir(parents=True, exist_ok=True)
    return repo_root, content_dir


def main() -> None:
    ensure_tools_available()
    _, content_dir = resolve_paths()
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        fail("GITHUB_TOKEN must be set before running this script.")

    run_id = latest_successful_run_id(token)
    artifacts = workflow_artifacts(run_id, token)

    for artifact in artifacts:
        download_artifact(artifact, content_dir, token)

    print("All artifacts downloaded successfully.")

if __name__ == "__main__":
    main()
