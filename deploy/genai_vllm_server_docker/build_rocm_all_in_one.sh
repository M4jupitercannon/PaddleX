#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Build a ROCm all-in-one PaddleOCR-VL 1.5 image.

Usage:
  ./deploy/genai_vllm_server_docker/build_rocm_all_in_one.sh [options]

Options:
  --tag TAG                       Docker image tag.
                                  Default: paddleocr-vl:latest-amd-gpu-all-in-one
  --model-source SOURCE          Value for PADDLE_PDX_MODEL_SOURCE.
                                  Default: bos
  --cache-home-dir DIR           Optional local PaddleX cache directory to merge into
                                  /opt/paddlex/cache inside the image.
                                  If DIR points to an official_models directory, it is
                                  staged under /opt/paddlex/cache/official_models.
  --dataset-dir DIR              Optional dataset directory to bundle into
                                  /opt/paddlex/datasets. May be passed multiple times.
  --dataset-url URL              Optional dataset tarball URL to download during
                                  docker build and extract into /opt/paddlex/datasets.
  --dataset-name NAME            Target subdirectory name for --dataset-url.
                                  Default: URL basename without archive suffix.
  --no-cache                     Forward --no-cache to docker build.
  -h, --help                     Show this help message.
EOF
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 127
    fi
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)

tag="paddleocr-vl:latest-amd-gpu-all-in-one"
model_source="bos"
cache_home_dir=""
dataset_url=""
dataset_name=""
declare -a dataset_dirs=()
declare -a docker_build_args=()

while (($# > 0)); do
    case "$1" in
        --tag)
            tag="$2"
            shift 2
            ;;
        --model-source)
            model_source="$2"
            shift 2
            ;;
        --cache-home-dir)
            cache_home_dir="$2"
            shift 2
            ;;
        --dataset-dir)
            dataset_dirs+=("$2")
            shift 2
            ;;
        --dataset-url)
            dataset_url="$2"
            shift 2
            ;;
        --dataset-name)
            dataset_name="$2"
            shift 2
            ;;
        --no-cache)
            docker_build_args+=("--no-cache")
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

require_cmd docker
require_cmd git
require_cmd rsync

git_sha=$(git -C "${REPO_ROOT}" rev-parse --short HEAD)
pretend_version="0.0.dev0+g${git_sha}"

if [[ -n "${dataset_name}" && -z "${dataset_url}" ]]; then
    echo "--dataset-name requires --dataset-url" >&2
    exit 2
fi

if [[ -n "${dataset_url}" && -z "${dataset_name}" ]]; then
    dataset_name=$(basename -- "${dataset_url}")
    dataset_name=${dataset_name%.tar.gz}
    dataset_name=${dataset_name%.tgz}
    dataset_name=${dataset_name%.tar}
    dataset_name=${dataset_name%.zip}
fi

context_dir=$(mktemp -d)
cleanup() {
    rm -rf "${context_dir}"
}
trap cleanup EXIT

mkdir -p "${context_dir}/PaddleX"
mkdir -p "${context_dir}/extra_data/cache"
mkdir -p "${context_dir}/extra_data/datasets"

rsync -a \
    --exclude ".git" \
    --exclude ".idea" \
    --exclude ".mypy_cache" \
    --exclude ".pytest_cache" \
    --exclude ".ruff_cache" \
    --exclude ".venv" \
    --exclude "__pycache__" \
    --exclude "node_modules" \
    "${REPO_ROOT}/" "${context_dir}/PaddleX/"

if [[ -n "${cache_home_dir}" ]]; then
    if [[ ! -d "${cache_home_dir}" ]]; then
        echo "Cache directory does not exist: ${cache_home_dir}" >&2
        exit 2
    fi

    if [[ "$(basename -- "${cache_home_dir}")" == "official_models" ]]; then
        mkdir -p "${context_dir}/extra_data/cache/official_models"
        rsync -a \
            "${cache_home_dir}/" \
            "${context_dir}/extra_data/cache/official_models/"
    else
        rsync -a \
            "${cache_home_dir}/" \
            "${context_dir}/extra_data/cache/"
    fi
fi

for dataset_dir in "${dataset_dirs[@]}"; do
    if [[ ! -d "${dataset_dir}" ]]; then
        echo "Dataset directory does not exist: ${dataset_dir}" >&2
        exit 2
    fi
    dataset_name=$(basename -- "${dataset_dir}")
    rsync -a \
        "${dataset_dir}/" \
        "${context_dir}/extra_data/datasets/${dataset_name}/"
done

DOCKER_BUILDKIT=1 docker build \
    -f "${context_dir}/PaddleX/deploy/genai_vllm_server_docker/Dockerfile.rocm.all_in_one" \
    -t "${tag}" \
    --build-arg "PADDLE_PDX_MODEL_SOURCE=${model_source}" \
    --build-arg "PADDLEX_PRETEND_VERSION=${pretend_version}" \
    --build-arg "BUNDLED_DATASET_NAME=${dataset_name}" \
    --build-arg "BUNDLED_DATASET_URL=${dataset_url}" \
    "${docker_build_args[@]}" \
    "${context_dir}"
