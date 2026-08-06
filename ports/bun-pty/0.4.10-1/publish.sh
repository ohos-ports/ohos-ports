#!/bin/sh
set -e

cd bun-pty-0.4.10
# --provenance 生成来源证明
npm stage publish --provenance --tag latest --access public
