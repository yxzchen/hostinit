#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

exec uv run --locked --project "$PROJECT_DIR" python "$PROJECT_DIR/src/build.py"

