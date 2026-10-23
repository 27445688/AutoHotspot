#!/bin/sh
# Builds the roothide and rootless packages into packages/.
set -e
cd "$(dirname "$0")"
for scheme in roothide rootless; do
    make clean >/dev/null
    make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=$scheme
done
