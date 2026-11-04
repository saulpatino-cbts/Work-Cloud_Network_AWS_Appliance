#!/usr/bin/env bash
set -euo pipefail

assert_tfstate_lock_table_isolation() {
  local environment="${1:-}"
  local target_table="${2:-}"
  local dev_table="${3:-}"
  local prod_table="${4:-}"

  if [[ "$environment" != "dev" && "$environment" != "prod" ]]; then
    echo "::error::environment must be dev or prod." >&2
    return 1
  fi
  for table in "$target_table" "$dev_table" "$prod_table"; do
    if [[ ! "$table" =~ ^[A-Za-z0-9_.-]{3,255}$ ]]; then
      echo "::error::The selected and both registered environment Terraform lock-table names must be configured." >&2
      return 1
    fi
  done
  if [[ "$dev_table" == "$prod_table" ]]; then
    echo "::error::Dev and prod must use distinct Terraform lock tables; refusing backend deletion." >&2
    return 1
  fi
  local registered_target="$dev_table"
  [[ "$environment" == "prod" ]] && registered_target="$prod_table"
  if [[ "$target_table" != "$registered_target" ]]; then
    echo "::error::TFSTATE_LOCK_TABLE does not match the registered $environment lock table." >&2
    return 1
  fi
}
