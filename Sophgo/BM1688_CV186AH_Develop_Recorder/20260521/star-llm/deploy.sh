#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <server-ip>"
    exit 1
fi

IP="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Packing star-llm.tar..."
cd "$SCRIPT_DIR"
tar cf star-llm.tar api_server.py chat.cpython-310-aarch64-linux-gnu.so config pipeline.py star-llm.service

echo "Uploading to linaro@$IP..."
scp star-llm.tar \
    install/qwen3.5-2b-int4-autoround_w4bf16_seq2048_bm1688_2core_dynamic_20260415_212627.bmodel \
    install/memory_edit_v2.12.deb \
    linaro@$IP:/data/

scp install_star_llm.sh linaro@$IP:/home/linaro/

echo "Done."
