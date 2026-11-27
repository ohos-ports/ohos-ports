#!/bin/sh
set -e

# Builds the @ohos-ports/playwright-core 1.62.1 artifact. All shared logic
# lives in ../build-common.sh; the playwright-ohos source commit is pinned in
# ../playwright-ohos-commit.txt and shared by every version.

VERSION=1.62.1

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$SCRIPT_DIR/../build-common.sh" "$VERSION"
