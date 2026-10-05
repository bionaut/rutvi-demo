#!/bin/sh
# Offline delivery checks. No Codex login or model calls are required.
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
export MIX_ENV=test
export RUTVI_MODEL_PROVIDER=deterministic
export RUTVI_MODEL_PROFILE=strict
# Do not let a caller's development database or demo listener leak into tests.
unset RUTVI_DATABASE RUTVI_STUDIO_DEMO HTTP_IDENTITIES
mix format --check-formatted
mix compile --warnings-as-errors
mix test
node --test test/studio_ui_test.js
for script in scripts/*.sh; do sh -n "$script"; done
# Preserve upstream Markdown hard breaks in the unmodified vendored source.
git diff --check -- . ":(exclude)vendor/**"
git diff --cached --check -- . ":(exclude)vendor/**"
