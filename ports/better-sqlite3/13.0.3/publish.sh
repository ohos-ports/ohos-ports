#!/bin/sh
set -e

cd better-sqlite3-13.0.3
# Preserve automatic Node/latest releases. Changes to Electron-only files must
# not try to republish an existing immutable Node version, or publish a prerelease
# through this path. Registry/network failures must fail instead of publishing.
node -e '
  const p = require("./package.json");
  if (p.name !== "@ohos-ports/better-sqlite3" || p.version !== "13.0.3") {
    throw new Error("Node publication only accepts the original stable 13.0.3 package");
  }
'
LOOKUP=$(mktemp)
trap 'rm -f "$LOOKUP" "$LOOKUP.err"' EXIT HUP INT TERM
if npm view @ohos-ports/better-sqlite3@13.0.3 version --json > "$LOOKUP" 2> "$LOOKUP.err"; then
  node -e '
    const v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    if (v !== "13.0.3") throw new Error("Unexpected registry version response");
  ' "$LOOKUP"
  echo "Node 13.0.3 is already published; keeping the existing latest tag unchanged"
  exit 0
else
  node -e '
    const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    if (!r.error || r.error.code !== "E404") throw new Error("Registry lookup failed; refusing publication");
  ' "$LOOKUP"
fi
# --ignore-scripts: build.sh 已完成全部准备工作（node-gyp 编译、签名、prebuild 生成），
# 跳过 prepublishOnly（upstream 的 prepare 脚本会尝试重新编译，无需重复）
npm publish --ignore-scripts --provenance --tag latest --access public
