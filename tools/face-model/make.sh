#!/bin/bash
# Creates the face-recognition model the server loads from <data location>/models/FaceNet.mlpackage.
# Needs uv (brew install uv) and network access once (Python packages + weights, ~1 GB download).
# Usage: tools/face-model/make.sh [output .mlpackage path]
set -euo pipefail
cd "$(dirname "$0")"
out=${1:-"$HOME/Library/Application Support/PhotoServer/models/FaceNet.mlpackage"}
mkdir -p "$(dirname "$out")"
[ -d .venv ] || uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -q "torch==2.5.1" "torchvision==0.20.1" "coremltools==8.3.0" "numpy<2" requests pillow tqdm
uv pip install --python .venv/bin/python -q --no-deps "facenet-pytorch==2.6.0"
.venv/bin/python convert.py "$out"
