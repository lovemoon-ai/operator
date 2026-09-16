#!/usr/bin/env bash

_curfile=$(realpath $0)
cur=$(dirname $_curfile)
cd ${cur}

SCALEBFM_ENV=/home/duino/ws/loco-manip/robot-locomanip/.venv-simple-main
SCALEBFM_CACHE=/home/duino/.cache/operator

LD_LIBRARY_PATH="$SCALEBFM_ENV/lib/python3.10/site-packages/nvidia/cuda_nvrtc/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
PYTHONPATH="$PWD/../../python:$PWD" \
"$SCALEBFM_ENV/bin/python" main.py \
  --backend torchscript \
  --device cuda \
  --checkpoint "$SCALEBFM_CACHE/models/scalebfm/model_22200_torchscript_cuda.pt" \
  --model "$SCALEBFM_CACHE/scalebfm/ScaleBFM/ScaleBridge/scalebridge/data/robot/g1_29dof/g1_29dof.xml"
