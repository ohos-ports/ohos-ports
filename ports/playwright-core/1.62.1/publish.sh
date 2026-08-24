#!/bin/sh
set -e

# Publishes the @ohos-ports/playwright-core 1.62.1 artifact built by
# build.sh. `npm stage publish` stages the release; a maintainer must
# approve it on npmjs.com before it goes live.

VERSION=1.62.1

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

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

# --provenance generates a build provenance attestation.
npm stage publish --provenance --tag latest --access public
