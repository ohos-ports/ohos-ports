#!/bin/sh
set -e

cd opentui-core-0.4.5
# --provenance 生成来源证明
npm stage publish --provenance --tag latest --access public
