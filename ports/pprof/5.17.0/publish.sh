#!/bin/sh
set -e

cd pprof-5.17.0
# --provenance 生成来源证明
npm stage publish --provenance --tag latest --access public
