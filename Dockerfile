# Stage 1: build deep_gemm ARM64 wheel on glibc 2.35 (Ubuntu 22.04) to match the vLLM image
FROM nvidia/cuda:13.0.0-devel-ubuntu22.04 AS dgbuilder
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    /root/.local/bin/uv python install 3.12 && \
    /root/.local/bin/uv venv /opt/dg --python 3.12 && \
    /root/.local/bin/uv pip install --python /opt/dg/bin/python \
      --index-url https://download.pytorch.org/whl/cu130 torch==2.13.0+cu130 && \
    /root/.local/bin/uv pip install --python /opt/dg/bin/python wheel setuptools pip
RUN git clone -q --depth 1 --branch v2.1.1.post3 --recurse-submodules https://github.com/deepseek-ai/DeepGEMM.git /src && \
    cd /src && CUDA_HOME=/usr/local/cuda PATH=/usr/local/cuda/bin:$PATH \
      /opt/dg/bin/pip wheel . --no-build-isolation --no-deps -w /out

# Stage 2: final serving image
FROM vllm/vllm-openai:v0.27.1
COPY --from=dgbuilder /out /wheels
RUN pip install --no-cache-dir /wheels/*.whl && rm -rf /wheels \
 && sed -i 's/if should_auto_disable_deep_gemm(model_type):/if should_auto_disable_deep_gemm(model_type) and not envs.VLLM_USE_DEEP_GEMM:/' \
      /usr/local/lib/python3.12/dist-packages/vllm/config/vllm.py \
 && (python3 -c "import torch; import deep_gemm" 2>/dev/null || echo "NB: import check deferred to runtime (libcuda absent during build)")
