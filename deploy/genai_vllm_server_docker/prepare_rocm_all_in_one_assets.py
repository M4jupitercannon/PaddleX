#!/usr/bin/env python3
# Copyright (c) 2026 PaddlePaddle Authors. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import argparse
import hashlib
import os
import tarfile
import tempfile
import urllib.request
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download and extract optional all-in-one build assets."
    )
    parser.add_argument("--asset-url", default="", help="Tarball URL to download.")
    parser.add_argument(
        "--asset-name", default="", help="Target subdirectory name after extraction."
    )
    parser.add_argument(
        "--asset-sha256",
        default="",
        help="Optional sha256 checksum in lowercase hex.",
    )
    parser.add_argument(
        "--asset-kind",
        choices=("dataset", "benchmark"),
        required=True,
        help="Label used in logs only.",
    )
    parser.add_argument(
        "--target-root",
        type=Path,
        required=True,
        help="Root directory where asset-name directory will be created.",
    )
    parser.add_argument(
        "--min-bytes",
        type=int,
        default=1024,
        help="Minimum downloaded file size validation threshold.",
    )
    return parser.parse_args()


def sha256sum(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file_obj:
        for chunk in iter(lambda: file_obj.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_within_directory(root_dir: Path, candidate: Path) -> bool:
    root_resolved = root_dir.resolve()
    candidate_resolved = candidate.resolve()
    return os.path.commonpath([str(root_resolved), str(candidate_resolved)]) == str(
        root_resolved
    )


def safe_extract(tar_path: Path, target_dir: Path) -> None:
    with tarfile.open(tar_path, mode="r:*") as archive:
        for member in archive.getmembers():
            destination = target_dir / member.name
            if not is_within_directory(target_dir, destination):
                raise RuntimeError(
                    f"Unsafe archive path detected for {tar_path}: {member.name}"
                )
        archive.extractall(path=target_dir)


def maybe_download_and_extract(
    asset_url: str,
    asset_name: str,
    asset_sha256: str,
    asset_kind: str,
    target_root: Path,
    min_bytes: int,
) -> None:
    if not asset_url:
        print(f"[skip] {asset_kind}: no url provided")
        return

    if not asset_name:
        raise ValueError(f"{asset_kind} asset_name is required when asset_url is set")

    safe_asset_name = Path(asset_name).name.strip()
    if not safe_asset_name:
        raise ValueError(f"{asset_kind} asset_name resolves to empty: {asset_name!r}")

    target_root.mkdir(parents=True, exist_ok=True)
    extract_dir = target_root / safe_asset_name
    extract_dir.mkdir(parents=True, exist_ok=True)
    tmp_fd, tmp_path = tempfile.mkstemp(
        prefix=f"{asset_kind}-{safe_asset_name}-", suffix=".tar", dir="/tmp"
    )
    os.close(tmp_fd)
    archive_path = Path(tmp_path)

    print(f"[download] {asset_kind}: {asset_url}")
    urllib.request.urlretrieve(asset_url, archive_path)

    actual_size = archive_path.stat().st_size
    if actual_size < min_bytes:
        raise RuntimeError(
            f"{asset_kind} archive is too small ({actual_size} bytes): {archive_path}"
        )

    if asset_sha256:
        actual_sha256 = sha256sum(archive_path)
        if actual_sha256 != asset_sha256.lower():
            raise RuntimeError(
                f"{asset_kind} checksum mismatch: expected {asset_sha256}, got {actual_sha256}"
            )
        print(f"[verify] {asset_kind}: sha256 ok")
    else:
        print(f"[verify] {asset_kind}: size ok ({actual_size} bytes)")

    print(f"[extract] {asset_kind}: {archive_path} -> {extract_dir}")
    safe_extract(archive_path, extract_dir)
    archive_path.unlink(missing_ok=True)


def main() -> None:
    args = parse_args()
    maybe_download_and_extract(
        asset_url=args.asset_url.strip(),
        asset_name=args.asset_name.strip(),
        asset_sha256=args.asset_sha256.strip(),
        asset_kind=args.asset_kind,
        target_root=args.target_root,
        min_bytes=args.min_bytes,
    )


if __name__ == "__main__":
    main()
