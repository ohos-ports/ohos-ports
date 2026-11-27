#!/bin/sh
set -e

# Publishes the @ohos-ports/playwright-core 1.51.0 artifact built by
# build.sh. All shared logic lives in ../publish-common.sh.

VERSION=1.51.0

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$SCRIPT_DIR/../publish-common.sh" "$VERSION"
