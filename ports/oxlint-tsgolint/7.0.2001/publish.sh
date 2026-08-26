#!/bin/sh
set -e

cd oxlint-tsgolint-7.0.2001

# npm stage publish requires the package to already exist on npm (404
# otherwise) — route on existence so the first release goes through plain
# npm publish (same lesson as ports/turbo/2.10.10/publish.sh).
if npm view @ohos-ports/oxlint-tsgolint version >/dev/null 2>&1; then
  npm stage publish --tag latest --access public
else
  npm publish --tag latest --access public
fi
