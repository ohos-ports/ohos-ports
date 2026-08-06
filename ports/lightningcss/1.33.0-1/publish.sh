#!/bin/sh
set -e

cd lightningcss-1.33.0
# --provenance 生成来源证明
npm stage publish --provenance --tag latest --access public
