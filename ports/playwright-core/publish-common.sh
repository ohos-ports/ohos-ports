#!/bin/sh
set -e

# Shared publish logic for @ohos-ports/playwright-core.
#
# Usage: publish-common.sh <version>
#
# Publishes the playwright-core-<version>/ artifact built by build-common.sh.
# `npm stage publish` stages the release; a maintainer must approve it on
# npmjs.com before it goes live.

VERSION=$1
if [ -z "$VERSION" ]; then
  echo "usage: publish-common.sh <version>" >&2
  exit 1
fi

ARTIFACT="playwright-core-$VERSION"
if [ ! -d "$ARTIFACT" ]; then
  echo "publish-common.sh: artifact not found: $ARTIFACT (run build.sh first)" >&2
  exit 1
fi

cd "$ARTIFACT"
NAME=$(node -e "console.log(require('./package.json').name)")
if [ "$NAME" != "@ohos-ports/playwright-core" ]; then
  echo "publish-common.sh: unexpected package name: $NAME" >&2
  exit 1
fi

# --provenance generates a build provenance attestation.
npm stage publish --provenance --tag latest --access public
