#!/bin/sh
set -e

# Publish the binary subpackage first so the main package's
# optionalDependency resolves immediately for early installers.
cd src/crates/node/npm/openharmony-arm64
npm stage publish --provenance --tag latest --access public
cd ../..
npm stage publish --provenance --tag latest --access public
