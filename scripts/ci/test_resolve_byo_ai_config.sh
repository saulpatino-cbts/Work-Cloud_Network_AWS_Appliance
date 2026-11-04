#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/resolve_byo_ai_config.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

resolve_byo_ai_config saas "" "" || fail "saas config was rejected"
[[ "$AI_ENGINE_DEFAULT" == "bedrock" && "$BYO_AI_PROVIDERS_JSON" == "[]" ]] || fail "saas config changed"

resolve_byo_ai_config byo-api anthropic '["anthropic"]' || fail "anthropic config was rejected"
[[ "$AI_ENGINE_DEFAULT" == "anthropic" && "$BYO_AI_PROVIDERS_JSON" == '["anthropic"]' ]] || fail "anthropic config was not normalized"

resolve_byo_ai_config byo-api openai '["anthropic","openai"]' || fail "multi-provider config was rejected"
[[ "$AI_ENGINE_DEFAULT" == "openai" && "$BYO_AI_PROVIDERS_JSON" == '["anthropic","openai"]' ]] || fail "multi-provider config changed"

for invalid in \
  "" \
  "[]" \
  "{}" \
  '["aws"]' \
  '["anthropic","anthropic"]' \
  '["anthropic",1]' \
  'not-json'; do
  if resolve_byo_ai_config byo-api anthropic "$invalid" >/dev/null 2>&1; then
    fail "invalid provider list was accepted: $invalid"
  fi
done

if resolve_byo_ai_config byo-api "" '["anthropic"]' >/dev/null 2>&1; then
  fail "missing default engine was accepted"
fi
if resolve_byo_ai_config byo-api openai '["anthropic"]' >/dev/null 2>&1; then
  fail "default engine outside allowlist was accepted"
fi
if resolve_byo_ai_config invalid bedrock '[]' >/dev/null 2>&1; then
  fail "invalid ai_mode was accepted"
fi

echo "All BYO AI configuration regression checks passed."
