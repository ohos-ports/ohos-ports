#!/bin/sh
set -e

cd turbo-2.10.10

# npm stage publish requires the package to already exist on npm (404
# otherwise) — route on existence so parallel matrix jobs don't depend on
# publish order (same lesson as ports/pprof/5.17.0/publish.sh).
if npm view @ohos-ports/turbo version >/dev/null 2>&1; then
  npm stage publish --provenance --tag latest --access public
else
  npm publish --tag latest --access public
fi
