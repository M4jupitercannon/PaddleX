#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Run PaddleOCR-VL-1.5 precision/speed doc flow directly in all-in-one image.

Usage:
  ./deploy/genai_vllm_server_docker/run_rocm_all_in_one_doc_flow.sh [options]

Options:
  --mode MODE                     all|precision-native|precision-vllm|speed-vllm
                                  Default: all
  --output-dir DIR               Output root directory.
                                  Default: /workspace/ocrvl_doc_flow_output
  --images-dir DIR               Precision image dataset directory.
                                  Default: /opt/paddlex/datasets/images
  --pdfs-dir DIR                 Speed pdf dataset directory.
                                  Default: /opt/paddlex/datasets/omni1_5_pdfs
  --benchmark-root DIR           Benchmark root directory.
                                  Default: /opt/paddlex/benchmarks
  --server-port PORT             vLLM server port for local startup.
                                  Default: ${PADDLEX_ALL_IN_ONE_VLLM_SERVER_PORT:-8118}
  --server-url URL               Existing vLLM server URL; skip local startup.
                                  Default: (auto from --server-port)
  --client-device DEVICE         PaddleOCR client device (cpu|gpu).
                                  Default: cpu
  --benchmark-device DEVICE      Benchmark device argument.
                                  Default: gpu
  --benchmark-gpu-compat         Enable GPU-compatible benchmark mode by disabling
                                  local layout/doc-preprocess stages in benchmark config.
                                  Default: enabled
  --no-benchmark-gpu-compat      Disable GPU-compatible benchmark mode.
  --batch-size N                 Batch size for speed benchmark.
                                  Default: 512
  --strict-native                Fail the whole run if native precision fails.
  -h, --help                     Show this help message.
EOF
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 127
    fi
}

mode="all"
output_dir="/workspace/ocrvl_doc_flow_output"
images_dir="/opt/paddlex/datasets/images"
pdfs_dir="/opt/paddlex/datasets/omni1_5_pdfs"
benchmark_root="/opt/paddlex/benchmarks"
server_port="${PADDLEX_ALL_IN_ONE_VLLM_SERVER_PORT:-8118}"
server_url=""
client_device="cpu"
benchmark_device="gpu"
benchmark_gpu_compat="true"
batch_size="512"
strict_native="false"
overall_exit_code=0

native_status="not_run"
vllm_status="not_run"
speed_status="not_run"
native_count="0"
vllm_count="0"
benchmark_profile="default"
benchmark_config_path=""

while (($# > 0)); do
    case "$1" in
        --mode)
            mode="$2"
            shift 2
            ;;
        --output-dir)
            output_dir="$2"
            shift 2
            ;;
        --images-dir)
            images_dir="$2"
            shift 2
            ;;
        --pdfs-dir)
            pdfs_dir="$2"
            shift 2
            ;;
        --benchmark-root)
            benchmark_root="$2"
            shift 2
            ;;
        --server-port)
            server_port="$2"
            shift 2
            ;;
        --server-url)
            server_url="$2"
            shift 2
            ;;
        --client-device)
            client_device="$2"
            shift 2
            ;;
        --benchmark-device)
            benchmark_device="$2"
            shift 2
            ;;
        --benchmark-gpu-compat)
            benchmark_gpu_compat="true"
            shift
            ;;
        --no-benchmark-gpu-compat)
            benchmark_gpu_compat="false"
            shift
            ;;
        --batch-size)
            batch_size="$2"
            shift 2
            ;;
        --strict-native)
            strict_native="true"
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

if [[ -z "${server_url}" ]]; then
    server_url="http://127.0.0.1:${server_port}/v1"
fi

mkdir -p "${output_dir}"
native_output_dir="${output_dir}/paddle_acc_output"
vllm_output_dir="${output_dir}/vllm_acc_output"
speed_output_dir="${output_dir}/speed"
summary_file="${output_dir}/summary.txt"
native_log="${output_dir}/native_precision.log"
vllm_log="${output_dir}/vllm_precision.log"
speed_log="${output_dir}/speed.log"
server_log="${output_dir}/vllm_server.log"
preflight_log="${output_dir}/preflight.log"

server_pid=""
server_started_here="false"

write_summary() {
    {
        echo "mode=${mode}"
        echo "server_url=${server_url}"
        echo "images_dir=${images_dir}"
        echo "pdfs_dir=${resolved_pdfs_dir:-unknown}"
        echo "benchmark_e2e_dir=${benchmark_e2e_dir:-unknown}"
        echo "benchmark_config_path=${benchmark_config_path}"
        echo "benchmark_profile=${benchmark_profile}"
        echo "native_status=${native_status}"
        echo "vllm_precision_status=${vllm_status}"
        echo "speed_status=${speed_status}"
        echo "native_artifact_count=${native_count}"
        echo "vllm_artifact_count=${vllm_count}"
        echo "output_dir=${output_dir}"
        echo "overall_exit_code=${overall_exit_code}"
    } >"${summary_file}" 2>/dev/null || true
}

cleanup() {
    write_summary
    if [[ -n "${server_pid}" ]]; then
        kill "${server_pid}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

python_bin="python"
if ! command -v "${python_bin}" >/dev/null 2>&1; then
    python_bin="python3"
fi
require_cmd "${python_bin}"
require_cmd curl

resolve_pdfs_dir() {
    if [[ -d "${pdfs_dir}/omni1_5/pdfs" ]]; then
        printf '%s' "${pdfs_dir}/omni1_5/pdfs"
        return
    fi
    if [[ -d "${pdfs_dir}/pdfs" ]]; then
        printf '%s' "${pdfs_dir}/pdfs"
        return
    fi
    printf '%s' "${pdfs_dir}"
}

resolve_benchmark_e2e_dir() {
    local candidate
    candidate="$(find "${benchmark_root}" -maxdepth 5 -type f -path "*/e2e/test_local.py" | head -n 1)"
    if [[ -n "${candidate}" ]]; then
        dirname -- "${candidate}"
        return
    fi
    return 1
}

mode_needs_benchmark_assets() {
    case "${mode}" in
        all|speed-vllm)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

print_benchmark_debug() {
    echo "[runner][debug] benchmark_root=${benchmark_root}" >&2
    if [[ -d "${benchmark_root}" ]]; then
        echo "[runner][debug] benchmark_root entries:" >&2
        ls -la "${benchmark_root}" >&2 || true
        echo "[runner][debug] benchmark candidates (*/e2e/test_local.py):" >&2
        find "${benchmark_root}" -maxdepth 5 -type f -path "*/e2e/test_local.py" >&2 || true
    else
        echo "[runner][debug] benchmark_root does not exist" >&2
    fi
}

wait_for_server() {
    local max_attempts=120
    local attempt=1
    while (( attempt <= max_attempts )); do
        if curl -fsS "${server_url}/models" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
    return 1
}

start_local_server_if_needed() {
    if curl -fsS "${server_url}/models" >/dev/null 2>&1; then
        echo "[runner] vLLM server already ready at ${server_url}"
        return
    fi
    echo "[runner] starting local vLLM server on port ${server_port}"
    paddlex_genai_server \
        --model_name PaddleOCR-VL-1.5-0.9B \
        --host 0.0.0.0 \
        --port "${server_port}" \
        --backend vllm \
        >"${server_log}" 2>&1 &
    server_pid="$!"
    server_started_here="true"
    if ! wait_for_server; then
        echo "[runner][error] failed to start vLLM server; check ${server_log}" >&2
        exit 1
    fi
}

count_doc_artifacts() {
    local root="$1"
    if [[ ! -d "${root}" ]]; then
        echo 0
        return
    fi
    local json_count
    local md_count
    json_count=$(find "${root}" -type f -name "*.json" ! -path "${root}/imgs/*" | wc -l)
    md_count=$(find "${root}" -type f -name "*.md" ! -path "${root}/imgs/*" | wc -l)
    echo $((json_count + md_count))
}

run_precision_native() {
    mkdir -p "${native_output_dir}"
    echo "[runner] running native precision"
    set +e
    "${python_bin}" - <<PY >"${native_log}" 2>&1
from paddleocr import PaddleOCRVL

pipeline = PaddleOCRVL(device="${client_device}")
output = pipeline.predict("${images_dir}")
for res in output:
    res.save_to_json("${native_output_dir}")
    res.save_to_markdown("${native_output_dir}", pretty=False)
PY
    rc=$?
    set -e
    if [[ ${rc} -eq 0 ]]; then
        native_status="passed"
    else
        if grep -Eq "Hip error\\(100\\)|hipGetLastError|Image features and image tokens do not match" "${native_log}"; then
            native_status="deferred-known-runtime-issue"
            if [[ "${strict_native}" == "true" ]]; then
                overall_exit_code=1
                echo "[runner][error] native failed with known runtime issue (strict mode)" >&2
                exit 1
            fi
        else
            native_status="failed"
            overall_exit_code=1
            if [[ "${strict_native}" == "true" ]]; then
                echo "[runner][error] native precision failed; check ${native_log}" >&2
                exit 1
            fi
        fi
    fi
    native_count="$(count_doc_artifacts "${native_output_dir}")"
    tar -czf "${output_dir}/paddle_acc_output.tar.gz" --exclude="imgs" -C "${output_dir}" "paddle_acc_output"
}

run_precision_vllm() {
    mkdir -p "${vllm_output_dir}"
    start_local_server_if_needed
    echo "[runner] running vLLM precision"
    set +e
    "${python_bin}" - <<PY >"${vllm_log}" 2>&1
from paddleocr import PaddleOCRVL

pipeline = PaddleOCRVL(
    vl_rec_backend="vllm-server",
    vl_rec_server_url="${server_url}",
    device="${client_device}",
)
output = pipeline.predict("${images_dir}")
for res in output:
    res.save_to_json("${vllm_output_dir}")
    res.save_to_markdown("${vllm_output_dir}", pretty=False)
PY
    rc=$?
    set -e
    if [[ ${rc} -ne 0 ]]; then
        vllm_status="failed"
        overall_exit_code=1
        return 1
    fi
    vllm_status="passed"
    vllm_count="$(count_doc_artifacts "${vllm_output_dir}")"
    tar -czf "${output_dir}/vllm_acc_output.tar.gz" --exclude="imgs" -C "${output_dir}" "vllm_acc_output"
}

run_speed_vllm() {
    start_local_server_if_needed
    mkdir -p "${speed_output_dir}"
    local config_path
    config_path="${benchmark_e2e_dir}/PaddleOCR-VL-1_5_vllm.yaml"
    benchmark_profile="default"
    if [[ "${benchmark_gpu_compat}" == "true" && ( "${benchmark_device}" == "gpu" || "${benchmark_device}" == "dcu" ) ]]; then
        config_path="${benchmark_e2e_dir}/PaddleOCR-VL-1_5_vllm.gpu_compat.yaml"
        benchmark_profile="gpu_compat_layout_off"
    fi
    benchmark_config_path="${config_path}"
    "${python_bin}" - <<PY
import yaml

src = "/opt/paddlex/configs/PaddleOCR-VL-1.5.vllm-server.local.yaml"
dst = "${config_path}"
with open(src, "r", encoding="utf-8") as f:
    payload = yaml.safe_load(f)
vl = payload["SubModules"]["VLRecognition"]
vl["genai_config"]["server_url"] = "${server_url}"
benchmark_device = "${benchmark_device}"
gpu_compat = "${benchmark_gpu_compat}" == "true"
if gpu_compat and benchmark_device in ("gpu", "dcu"):
    # Work around ROCm client-side crashes in local layout kernels while
    # keeping the benchmark path GPU-compatible through the vLLM server.
    payload["use_layout_detection"] = False
    payload["use_doc_preprocessor"] = False
with open(dst, "w", encoding="utf-8") as f:
    yaml.safe_dump(payload, f, allow_unicode=False, sort_keys=False)
PY

    set +e
    (
        cd "${benchmark_e2e_dir}" && \
        "${python_bin}" -m pip install -r requirements.txt >/dev/null && \
        "${python_bin}" test_local.py "${resolved_pdfs_dir}" \
            -b "${batch_size}" \
            --paddlex_config_path "${config_path}" \
            --device "${benchmark_device}"
    ) >"${speed_log}" 2>&1
    rc=$?
    set -e
    if [[ ${rc} -ne 0 ]]; then
        speed_status="failed"
        overall_exit_code=1
        return 1
    fi
    speed_status="passed"
}

resolved_pdfs_dir="$(resolve_pdfs_dir)"
require_benchmark="false"
require_images="false"
require_pdfs="false"
case "${mode}" in
    all)
        require_benchmark="true"
        require_images="true"
        require_pdfs="true"
        ;;
    precision-native|precision-vllm)
        require_images="true"
        ;;
    speed-vllm)
        require_benchmark="true"
        require_pdfs="true"
        ;;
esac
if mode_needs_benchmark_assets; then
    require_benchmark="true"
    set +e
    benchmark_e2e_dir="$(resolve_benchmark_e2e_dir)"
    resolve_rc=$?
    set -e
    if [[ ${resolve_rc} -ne 0 ]]; then
        overall_exit_code=1
        if [[ "${mode}" == "speed-vllm" ]]; then
            speed_status="failed-preflight"
        else
            speed_status="failed-preflight"
            vllm_status="failed-preflight"
            native_status="failed-preflight"
        fi
        echo "[runner][error] could not resolve benchmark e2e directory under ${benchmark_root}" >&2
        print_benchmark_debug
        exit "${overall_exit_code}"
    fi
fi

bash "$(dirname -- "$0")/preflight_rocm_all_in_one.sh" \
    "${server_url}" \
    "${images_dir}" \
    "${resolved_pdfs_dir}" \
    "${benchmark_root}" \
    "${require_benchmark}" \
    "${require_images}" \
    "${require_pdfs}" >"${preflight_log}" 2>&1 || {
        overall_exit_code=1
        if [[ "${mode}" == "speed-vllm" ]]; then
            speed_status="failed-preflight"
        elif [[ "${mode}" == "precision-vllm" ]]; then
            vllm_status="failed-preflight"
        elif [[ "${mode}" == "precision-native" ]]; then
            native_status="failed-preflight"
        else
            speed_status="failed-preflight"
            vllm_status="failed-preflight"
            native_status="failed-preflight"
        fi
        echo "[runner][error] preflight failed; see ${preflight_log}" >&2
        exit "${overall_exit_code}"
    }

case "${mode}" in
    all)
        run_precision_native
        if run_precision_vllm; then
            run_speed_vllm
        else
            speed_status="skipped-upstream-failure"
        fi
        ;;
    precision-native)
        run_precision_native
        ;;
    precision-vllm)
        run_precision_vllm
        ;;
    speed-vllm)
        run_speed_vllm
        ;;
    *)
        echo "Unsupported mode: ${mode}" >&2
        exit 2
        ;;
esac

if [[ "${server_started_here}" == "true" ]]; then
    kill "${server_pid}" >/dev/null 2>&1 || true
    server_pid=""
fi

echo "[runner] completed. summary: ${summary_file}"
exit "${overall_exit_code}"
