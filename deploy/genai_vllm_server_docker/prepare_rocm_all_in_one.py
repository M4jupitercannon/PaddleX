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
import copy
import json
from pathlib import Path
from typing import Any, Dict, Iterable, List

import yaml

from paddlex.inference.utils.official_models import official_models


def parse_args():
    parser = argparse.ArgumentParser(
        description="Preload PaddleOCR-VL 1.5 assets for the ROCm all-in-one image."
    )
    parser.add_argument(
        "--pipeline-config",
        type=Path,
        required=True,
        help="Path to the PaddleOCR-VL 1.5 pipeline YAML file.",
    )
    parser.add_argument(
        "--output-config-dir",
        type=Path,
        required=True,
        help="Directory where local pipeline configs will be written.",
    )
    parser.add_argument(
        "--dataset-dir",
        type=Path,
        required=True,
        help="Directory inside the image that stores bundled datasets.",
    )
    parser.add_argument(
        "--server-url",
        type=str,
        default="http://127.0.0.1:8080/v1",
        help="OpenAI-compatible vLLM endpoint used by the generated server config.",
    )
    return parser.parse_args()


def load_yaml(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def dump_yaml(path: Path, payload: Dict[str, Any]) -> None:
    with path.open("w", encoding="utf-8") as f:
        yaml.safe_dump(payload, f, allow_unicode=False, sort_keys=False)


def collect_model_names(node: Any) -> List[str]:
    model_names: List[str] = []

    if isinstance(node, dict):
        model_name = node.get("model_name")
        if isinstance(model_name, str):
            model_names.append(model_name)
        for value in node.values():
            model_names.extend(collect_model_names(value))
    elif isinstance(node, list):
        for item in node:
            model_names.extend(collect_model_names(item))

    return model_names


def unique_strings(values: Iterable[str]) -> List[str]:
    seen = set()
    ordered: List[str] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        ordered.append(value)
    return ordered


def resolve_model_dirs(model_names: Iterable[str]) -> Dict[str, str]:
    resolved: Dict[str, str] = {}
    for model_name in model_names:
        resolved[model_name] = str(official_models[model_name])
    return resolved


def inject_local_model_dirs(node: Any, model_dirs: Dict[str, str]) -> None:
    if isinstance(node, dict):
        model_name = node.get("model_name")
        if (
            isinstance(model_name, str)
            and model_name in model_dirs
            and "model_dir" in node
        ):
            node["model_dir"] = model_dirs[model_name]
        for value in node.values():
            inject_local_model_dirs(value, model_dirs)
    elif isinstance(node, list):
        for item in node:
            inject_local_model_dirs(item, model_dirs)


def build_native_config(
    base_config: Dict[str, Any], model_dirs: Dict[str, str]
) -> Dict[str, Any]:
    native_config = copy.deepcopy(base_config)
    inject_local_model_dirs(native_config, model_dirs)
    return native_config


def build_vllm_server_config(
    native_config: Dict[str, Any], server_url: str
) -> Dict[str, Any]:
    server_config = copy.deepcopy(native_config)
    vl_recognition = server_config["SubModules"]["VLRecognition"]
    vl_recognition["model_dir"] = None
    vl_recognition["genai_config"] = {
        "backend": "vllm-server",
        "server_url": server_url,
    }
    return server_config


def build_manifest(
    model_dirs: Dict[str, str],
    pipeline_config_path: Path,
    output_config_dir: Path,
    dataset_dir: Path,
    server_url: str,
) -> Dict[str, Any]:
    return {
        "pipeline_config": str(pipeline_config_path),
        "output_config_dir": str(output_config_dir),
        "dataset_dir": str(dataset_dir),
        "server_url": server_url,
        "resolved_model_dirs": model_dirs,
    }


def main():
    args = parse_args()

    base_config = load_yaml(args.pipeline_config)
    model_names = unique_strings(collect_model_names(base_config))
    model_dirs = resolve_model_dirs(model_names)

    args.output_config_dir.mkdir(parents=True, exist_ok=True)
    args.dataset_dir.mkdir(parents=True, exist_ok=True)

    native_config = build_native_config(base_config, model_dirs)
    vllm_server_config = build_vllm_server_config(native_config, args.server_url)

    native_config_path = (
        args.output_config_dir / "PaddleOCR-VL-1.5.native.local.yaml"
    )
    vllm_server_config_path = (
        args.output_config_dir / "PaddleOCR-VL-1.5.vllm-server.local.yaml"
    )
    manifest_path = args.output_config_dir / "PaddleOCR-VL-1.5.manifest.json"

    dump_yaml(native_config_path, native_config)
    dump_yaml(vllm_server_config_path, vllm_server_config)
    with manifest_path.open("w", encoding="utf-8") as f:
        json.dump(
            build_manifest(
                model_dirs=model_dirs,
                pipeline_config_path=args.pipeline_config,
                output_config_dir=args.output_config_dir,
                dataset_dir=args.dataset_dir,
                server_url=args.server_url,
            ),
            f,
            indent=2,
            sort_keys=True,
        )
        f.write("\n")

    print("Prepared the ROCm all-in-one image assets:")
    print(f"  native config: {native_config_path}")
    print(f"  vLLM config:   {vllm_server_config_path}")
    print(f"  manifest:      {manifest_path}")
    print("  bundled models:")
    for model_name, model_dir in model_dirs.items():
        print(f"    - {model_name}: {model_dir}")


if __name__ == "__main__":
    main()
