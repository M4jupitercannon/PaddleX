#!/usr/bin/env bash

set -euo pipefail

server_url="${1:-http://127.0.0.1:8118/v1}"
images_dir="${2:-/opt/paddlex/datasets/images}"
pdfs_dir="${3:-/opt/paddlex/datasets/omni1_5_pdfs}"
benchmark_root="${4:-/opt/paddlex/benchmarks}"

fail() {
    echo "[preflight][error] $*" >&2
    exit 1
}

python_bin="python"
if ! command -v "${python_bin}" >/dev/null 2>&1; then
    python_bin="python3"
fi
command -v "${python_bin}" >/dev/null 2>&1 || fail "python or python3 is required"

echo "[preflight] checking python modules"
"${python_bin}" - <<'PY'
import importlib
required = ["paddlex", "paddleocr", "yaml"]
for name in required:
    importlib.import_module(name)
print("[preflight] python imports ok")
PY

echo "[preflight] checking ROCm device files"
[[ -e /dev/kfd ]] || fail "/dev/kfd is missing"
[[ -d /dev/dri ]] || fail "/dev/dri is missing"

echo "[preflight] checking datasets"
[[ -d "${images_dir}" ]] || fail "images directory missing: ${images_dir}"
[[ -d "${pdfs_dir}" ]] || fail "pdf directory missing: ${pdfs_dir}"

echo "[preflight] checking benchmark assets"
[[ -d "${benchmark_root}" ]] || fail "benchmark root missing: ${benchmark_root}"
if ! find "${benchmark_root}" -maxdepth 5 -type f -path "*/e2e/test_local.py" | grep -q .; then
    fail "could not find benchmark e2e/test_local.py under ${benchmark_root}"
fi

echo "[preflight] probing server: ${server_url}/models"
if command -v curl >/dev/null 2>&1; then
    if ! curl -fsS "${server_url}/models" >/dev/null 2>&1; then
        echo "[preflight][warn] vLLM server is not ready yet; runner may start one."
    fi
fi

echo "[preflight] passed"
