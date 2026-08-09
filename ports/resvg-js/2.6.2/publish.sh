#!/bin/sh
set -e

cd resvg-js-2.6.2
npm stage publish --provenance --tag latest --access public
