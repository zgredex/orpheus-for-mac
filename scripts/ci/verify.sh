#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"

"$ROOT/scripts/ci/verify_architecture.sh"
"$ROOT/scripts/ci/verify_native_binaries.sh"
"$ROOT/scripts/ci/verify_project_drift.sh"
"$ROOT/scripts/ci/test_core.sh"
"$ROOT/scripts/ci/test_app.sh"
