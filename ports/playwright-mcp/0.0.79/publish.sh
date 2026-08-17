#!/bin/sh
set -e

cd playwright-mcp-0.0.79

# npm stage publish 要求包在 npm 上已存在，首发（包不存在）会 404
# （同 ports/pprof/5.17.0/publish.sh 的实测教训）。因此按包是否存在选路：
# 不存在则直接 publish 创建包，已存在则走 stage + provenance（维护者 2FA 审核上线）。
if npm view @ohos-ports/playwright-mcp version >/dev/null 2>&1; then
  npm stage publish --provenance --tag latest --access public
else
  npm publish --tag latest --access public
fi
