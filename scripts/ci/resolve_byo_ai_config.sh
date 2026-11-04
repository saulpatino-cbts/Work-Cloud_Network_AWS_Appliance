#!/usr/bin/env bash
set -euo pipefail

resolve_byo_ai_config() {
  local mode="${1:-}"
  local configured_default="${2:-}"
  local configured_providers="${3:-}"
  local providers_json

  case "$mode" in
    saas)
      export AI_ENGINE_DEFAULT="bedrock"
      export BYO_AI_PROVIDERS_JSON="[]"
      return 0
      ;;
    byo-api)
      if [[ "$configured_default" != "anthropic" && "$configured_default" != "openai" ]]; then
        echo "::error::CNA_AI_ENGINE_DEFAULT must be anthropic or openai when ai_mode is byo-api."
        return 1
      fi
      if ! providers_json=$(jq -ce '
        if type == "array"
          and length > 0
          and all(.[]; . == "anthropic" or . == "openai")
          and (unique | length) == length
        then .
        else error("expected a non-empty array of unique anthropic/openai providers")
        end
      ' <<<"$configured_providers"); then
        echo "::error::CNA_BYO_AI_PROVIDERS must be a non-empty JSON array containing only unique values from anthropic and openai."
        return 1
      fi
      if ! jq -e --arg engine "$configured_default" 'index($engine) != null' <<<"$providers_json" >/dev/null; then
        echo "::error::CNA_BYO_AI_PROVIDERS must include CNA_AI_ENGINE_DEFAULT."
        return 1
      fi
      export AI_ENGINE_DEFAULT="$configured_default"
      export BYO_AI_PROVIDERS_JSON="$providers_json"
      return 0
      ;;
    *)
      echo "::error::ai_mode must be saas or byo-api."
      return 1
      ;;
  esac
}
