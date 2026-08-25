#!/bin/sh
set -e

# Publishes the playwright-core-1.60.0/ artifact built by build.sh as
# @ohos-ports/playwright-core@1.60.0-1.
# npm stage publish requires the package to already exist on npm (404
# otherwise) — route on existence so a first-ever release goes through a
# plain publish and later ones through `npm stage publish --provenance`,
# which a maintainer must approve on npmjs.com before it goes live (same
# lesson as ports/pprof/5.17.0/publish.sh).

VERSION=1.60.0

ARTIFACT="playwright-core-$VERSION"
if [ ! -d "$ARTIFACT" ]; then
  echo "publish.sh: artifact not found: $ARTIFACT (run build.sh first)" >&2
  exit 1
fi

cd "$ARTIFACT"
NAME=$(node -e "console.log(require('./package.json').name)")
if [ "$NAME" != "@ohos-ports/playwright-core" ]; then
  echo "publish.sh: unexpected package name: $NAME" >&2
  exit 1
fi

if npm view @ohos-ports/playwright-core version >/dev/null 2>&1; then
  # --provenance generates a build provenance attestation.
  npm stage publish --provenance --tag latest --access public
else
  npm publish --tag latest --access public
fi
