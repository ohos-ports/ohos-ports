#!/bin/sh
set -e

cd playwright-core-1.60.0

# npm stage publish 要求包在 npm 上已存在，首发（包不存在）会 404
# （同 ports/pprof/5.17.0/publish.sh 的实测教训）。因此按包是否存在选路：
# 不存在则直接 publish 创建包，已存在则走 stage + provenance（维护者 2FA 审核上线）。
# 这样同 PR 内多个版本目录在 CI 并行 matrix 下无先后顺序依赖。
if npm view @ohos-ports/playwright-core version >/dev/null 2>&1; then
  npm stage publish --provenance --tag latest --access public
else
  npm publish --tag latest --access public
fi
