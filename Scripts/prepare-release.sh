#!/bin/bash
# Compatibility shim: the canonical script is prepare-public-release.sh (see the
# realm-based naming in docs/LOCAL_DEVELOPMENT.md). This name is kept so the
# Build FFI XCFramework workflow and existing automation keep working unchanged.
exec "$(dirname "$0")/prepare-public-release.sh" "$@"
