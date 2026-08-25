#!/bin/sh
set -e

cd playwright-core-1.63.0-alpha-2026-08-05

# This is a playwright prerelease (needed by @playwright/mcp@0.0.79's pinned
# dependency), so it must not claim the "latest" dist-tag -- that would make a
# bare `npm install @ohos-ports/playwright-core` resolve to an alpha build
# instead of the newest stable release. Consumers pin this exact version via
# npm:@ohos-ports/playwright-core@1.63.0-alpha-2026-08-05-1 anyway.
#
# npm stage publish 要求包在 npm 上已存在，首发（包不存在）会 404
# （同 ports/pprof/5.17.0/publish.sh 的实测教训）。因此按包是否存在选路：
# 不存在则直接 publish 创建包，已存在则走 stage + provenance（维护者 2FA 审核上线）。
# 这样同 PR 内多个版本目录在 CI 并行 matrix 下无先后顺序依赖。
if npm view @ohos-ports/playwright-core version >/dev/null 2>&1; then
  npm stage publish --provenance --tag alpha --access public
else
  npm publish --tag alpha --access public
fi
