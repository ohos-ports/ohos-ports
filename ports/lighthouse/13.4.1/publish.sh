#!/bin/sh
set -e

cd lighthouse-13.4.1-beta.3
# --ignore-scripts: build.sh 已完成全部准备工作（补丁应用、dev 文件清理），
# 跳过 prepack（upstream 的构建脚本会尝试重新编译 report bundle，无需重复）
npm publish --ignore-scripts --provenance --tag beta --access public
