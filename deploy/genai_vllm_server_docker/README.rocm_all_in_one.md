# ROCm All-In-One PaddleOCR-VL 1.5 Image

This build path creates a self-contained ROCm image for `PaddleOCR-VL-1.5-0.9B`.

Compared with the existing minimal ROCm image, this variant also:

- preloads the PaddleOCR-VL 1.5 pipeline assets into `/opt/paddlex/cache`
- writes ready-to-use local pipeline configs into `/opt/paddlex/configs`
- optionally bundles extra dataset directories into `/opt/paddlex/datasets`

## Build

From the repository root:

```bash
./deploy/genai_vllm_server_docker/build_rocm_all_in_one.sh \
  --tag paddleocr-vl:latest-amd-gpu-all-in-one
```

If you already have a local PaddleX cache or extra dataset directories, you can merge them into the image:

```bash
./deploy/genai_vllm_server_docker/build_rocm_all_in_one.sh \
  --tag paddleocr-vl:latest-amd-gpu-all-in-one \
  --cache-home-dir /path/to/.paddlex \
  --dataset-dir /path/to/dataset_a \
  --dataset-dir /path/to/dataset_b
```

If `--cache-home-dir` points directly at an `official_models` directory, it will be staged into `/opt/paddlex/cache/official_models`.

Example: download the internal `images.tar` sample pack during image build:

```bash
./deploy/genai_vllm_server_docker/build_rocm_all_in_one.sh \
  --tag paddleocr-vl:latest-amd-gpu-all-in-one \
  --dataset-url https://paddle-model-ecology.bj.bcebos.com/paddlex/PaddleX3.0/deploy/internal/tmp/images.tar \
  --dataset-name images
```

With that example, the tarball is downloaded during `docker build` and extracted into `/opt/paddlex/datasets/images` inside the container.

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

The server listens on port `8080` and serves an OpenAI-compatible endpoint at `http://127.0.0.1:8080/v1`.

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
