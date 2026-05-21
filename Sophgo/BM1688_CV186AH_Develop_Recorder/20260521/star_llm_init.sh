#!/bin/bash
set -e

APP_DIR=/opt/tunstar/star-llm
VENV_DIR=${APP_DIR}/star-llm-env
DONE_FLAG=${APP_DIR}/.init_done
PYPI=https://pypi.tuna.tsinghua.edu.cn/simple

[ -d "${APP_DIR}" ] || exit 1
[ -f "${DONE_FLAG}" ] && exit 0

cd "${APP_DIR}"

if [ ! -x "${VENV_DIR}/bin/python3" ]; then
  uv venv --python 3.10 --seed "${VENV_DIR}"
fi

uv pip install --python "${VENV_DIR}/bin/python3" --upgrade pip --index-url "${PYPI}"
uv pip install --python "${VENV_DIR}/bin/python3" \
  fastapi==0.115.0 \
  uvicorn==0.32.0 \
  pydantic==2.8.2 \
  numpy==1.26.4 \
  pillow==12.2.0 \
  transformers==5.5.4 \
  qwen-vl-utils==0.0.14 \
  torch==2.6.0 \
  torchvision==0.21.0 \
  -i "${PYPI}"

touch "${DONE_FLAG}"
exit 0