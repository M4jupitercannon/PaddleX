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
  --server-port PORT             Default vLLM server port baked in image.
                                  Default: 8118
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
  --precision-dataset-url URL    Precision test images tarball URL.
                                  Default: official images.tar from the test doc.
  --precision-dataset-name NAME  Extracted subdirectory name for precision dataset.
                                  Default: images
  --precision-dataset-sha256 X   Optional sha256 checksum for precision dataset tar.
  --speed-dataset-url URL        Speed test pdf tarball URL.
                                  Default: official omni1_5_pdfs.tar from the test doc.
  --speed-dataset-name NAME      Extracted subdirectory name for speed dataset.
                                  Default: omni1_5_pdfs
  --speed-dataset-sha256 X       Optional sha256 checksum for speed dataset tar.
  --benchmark-url URL            Speed benchmark tarball URL.
                                  Default: official ocr-vlm-benchmark-f29cfe4.tar.
  --benchmark-name NAME          Extracted subdirectory name for benchmark assets.
                                  Default: ocr-vlm-benchmark-f29cfe4
  --benchmark-sha256 X           Optional sha256 checksum for benchmark tar.
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
server_port="8118"
model_source="bos"
cache_home_dir=""
dataset_url=""
dataset_name=""
precision_dataset_url="https://paddle-model-ecology.bj.bcebos.com/paddlex/PaddleX3.0/deploy/internal/tmp/images.tar"
precision_dataset_name="images"
precision_dataset_sha256=""
speed_dataset_url="https://paddle-model-ecology.bj.bcebos.com/paddlex/PaddleX3.0/deploy/internal/tmp/omni1_5_pdfs.tar"
speed_dataset_name="omni1_5_pdfs"
speed_dataset_sha256=""
benchmark_url="https://paddle-model-ecology.bj.bcebos.com/paddlex/PaddleX3.0/deploy/internal/tmp/ocr-vlm-benchmark-f29cfe4.tar"
benchmark_name="ocr-vlm-benchmark-f29cfe4"
benchmark_sha256=""
declare -a dataset_dirs=()
declare -a docker_build_args=()

while (($# > 0)); do
    case "$1" in
        --tag)
            tag="$2"
            shift 2
            ;;
        --server-port)
            server_port="$2"
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
        --precision-dataset-url)
            precision_dataset_url="$2"
            shift 2
            ;;
        --precision-dataset-name)
            precision_dataset_name="$2"
            shift 2
            ;;
        --precision-dataset-sha256)
            precision_dataset_sha256="$2"
            shift 2
            ;;
        --speed-dataset-url)
            speed_dataset_url="$2"
            shift 2
            ;;
        --speed-dataset-name)
            speed_dataset_name="$2"
            shift 2
            ;;
        --speed-dataset-sha256)
            speed_dataset_sha256="$2"
            shift 2
            ;;
        --benchmark-url)
            benchmark_url="$2"
            shift 2
            ;;
        --benchmark-name)
            benchmark_name="$2"
            shift 2
            ;;
        --benchmark-sha256)
            benchmark_sha256="$2"
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

if [[ -n "${dataset_url}" ]]; then
    precision_dataset_url="${dataset_url}"
    dataset_url=""
fi
if [[ -n "${dataset_name}" ]]; then
    precision_dataset_name="${dataset_name}"
    dataset_name=""
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
    --build-arg "VLLM_SERVER_PORT=${server_port}" \
    --build-arg "BUNDLED_DATASET_NAME=${dataset_name}" \
    --build-arg "BUNDLED_DATASET_URL=${dataset_url}" \
    --build-arg "PRECISION_DATASET_URL=${precision_dataset_url}" \
    --build-arg "PRECISION_DATASET_NAME=${precision_dataset_name}" \
    --build-arg "PRECISION_DATASET_SHA256=${precision_dataset_sha256}" \
    --build-arg "SPEED_DATASET_URL=${speed_dataset_url}" \
    --build-arg "SPEED_DATASET_NAME=${speed_dataset_name}" \
    --build-arg "SPEED_DATASET_SHA256=${speed_dataset_sha256}" \
    --build-arg "BENCHMARK_ASSET_URL=${benchmark_url}" \
    --build-arg "BENCHMARK_ASSET_NAME=${benchmark_name}" \
    --build-arg "BENCHMARK_ASSET_SHA256=${benchmark_sha256}" \
    "${docker_build_args[@]}" \
    "${context_dir}"
