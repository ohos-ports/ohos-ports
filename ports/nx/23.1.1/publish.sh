#!/bin/sh
set -e

cd nx-23.1.1
# --ignore-scripts: build.sh already did all the work (cargo build, tsc
# compile, patches, signing); the upstream postinstall is a try/catch no-op.
npm stage publish --ignore-scripts --provenance --tag latest --access public
