# ROCm All-In-One PaddleOCR-VL 1.5 Image

This build path creates a self-contained ROCm image for `PaddleOCR-VL-1.5-0.9B`.

Compared with the existing minimal ROCm image, this variant also:

- preloads the PaddleOCR-VL 1.5 pipeline assets into `/opt/paddlex/cache`
- writes ready-to-use local pipeline configs into `/opt/paddlex/configs`
- optionally bundles extra dataset directories into `/opt/paddlex/datasets`
- can bundle precision/speed benchmark assets from the official test doc URLs

## Build

From the repository root:

```bash
./deploy/genai_vllm_server_docker/build_rocm_all_in_one.sh \
  --tag paddleocr-vl:latest-amd-gpu-all-in-one
```

This build now defaults to doc-compatible vLLM port `8118`, and includes:

- precision images dataset (`images.tar`)
- speed pdf dataset (`omni1_5_pdfs.tar`)
- benchmark scripts (`ocr-vlm-benchmark-f29cfe4.tar`)

The build now validates benchmark extraction by requiring `**/e2e/test_local.py` in the bundled benchmark asset. If this file is missing, the image build fails fast.

If you already have a local PaddleX cache or extra dataset directories, you can merge them into the image:

```bash
./deploy/genai_vllm_server_docker/build_rocm_all_in_one.sh \
  --tag paddleocr-vl:latest-amd-gpu-all-in-one \
  --cache-home-dir /path/to/.paddlex \
  --dataset-dir /path/to/dataset_a \
  --dataset-dir /path/to/dataset_b
```

If `--cache-home-dir` points directly at an `official_models` directory, it will be staged into `/opt/paddlex/cache/official_models`.

You can override asset URLs, names, checksums, and server port:

```bash
./deploy/genai_vllm_server_docker/build_rocm_all_in_one.sh \
  --tag paddleocr-vl:latest-amd-gpu-all-in-one \
  --server-port 8118 \
  --precision-dataset-url https://paddle-model-ecology.bj.bcebos.com/paddlex/PaddleX3.0/deploy/internal/tmp/images.tar \
  --precision-dataset-name images \
  --speed-dataset-url https://paddle-model-ecology.bj.bcebos.com/paddlex/PaddleX3.0/deploy/internal/tmp/omni1_5_pdfs.tar \
  --speed-dataset-name omni1_5_pdfs \
  --benchmark-url https://paddle-model-ecology.bj.bcebos.com/paddlex/PaddleX3.0/deploy/internal/tmp/ocr-vlm-benchmark-f29cfe4.tar \
  --benchmark-name ocr-vlm-benchmark-f29cfe4
```

If you pass `--precision-dataset-sha256`, `--speed-dataset-sha256`, or `--benchmark-sha256`, the Docker build validates checksums before extraction.

## Run The Server

This image starts the OCR-VL 1.5 vLLM server by default:

```bash
docker run \
  -it \
  --rm \
  --network host \
  --device=/dev/kfd \
  --device=/dev/dri \
  --group-add video \
  --ipc=host \
  paddleocr-vl:latest-amd-gpu-all-in-one
```

The server listens on port `8118` by default and serves an OpenAI-compatible endpoint at `http://127.0.0.1:8118/v1`.

To run on a different port:

```bash
docker run \
  -it \
  --rm \
  --network host \
  --device=/dev/kfd \
  --device=/dev/dri \
  --group-add video \
  --ipc=host \
  -e PADDLEX_ALL_IN_ONE_VLLM_SERVER_PORT=8111 \
  paddleocr-vl:latest-amd-gpu-all-in-one
```

## Run Inside The Container

To open an interactive shell instead of starting the server:

```bash
docker run \
  -it \
  --rm \
  --network host \
  --device=/dev/kfd \
  --device=/dev/dri \
  --group-add video \
  --ipc=host \
  paddleocr-vl:latest-amd-gpu-all-in-one \
  /bin/bash
```

Inside the container, the generated configs are:

- `/opt/paddlex/configs/PaddleOCR-VL-1.5.native.local.yaml`
- `/opt/paddlex/configs/PaddleOCR-VL-1.5.vllm-server.local.yaml`

The bundled assets are stored at:

- models: `/opt/paddlex/cache`
- datasets: `/opt/paddlex/datasets`
- benchmark assets: `/opt/paddlex/benchmarks`

Example native inference from inside the container:

```bash
python - <<'PY'
from paddlex import create_pipeline

pipeline = create_pipeline("/opt/paddlex/configs/PaddleOCR-VL-1.5.native.local.yaml")
for res in pipeline.predict(
    "https://paddle-model-ecology.bj.bcebos.com/paddlex/imgs/demo_image/pp_ocr_vl_demo.png"
):
    res.print()
PY
```

## Run The Precision/Speed Doc Flow Directly

Inside the all-in-one container:

```bash
bash /workspace/PaddleX/deploy/genai_vllm_server_docker/run_rocm_all_in_one_doc_flow.sh \
  --mode all \
  --output-dir /workspace/ocrvl_doc_flow_output
```

Generated outputs include:

- `paddle_acc_output` and `vllm_acc_output` folders
- `paddle_acc_output.tar.gz` and `vllm_acc_output.tar.gz`
- speed benchmark logs and a `summary.txt`

If native precision hits known ROCm runtime issues, the script marks native as deferred and continues vLLM precision/speed (unless `--strict-native` is set).

For ROCm environments where benchmark `--device gpu` crashes in local layout kernels, keep GPU benchmark mode enabled (default). The runner will auto-generate a GPU-compatible benchmark config by disabling local layout/doc-preprocess stages while keeping vLLM on GPU.
When this mode is used, `summary.txt` records `benchmark_profile=gpu_compat_layout_off` so results are clearly marked as GPU-compatible fallback metrics.
