#!/usr/bin/env bash
set -euo pipefail

assert_distinct_aws_accounts() {
  local environment="${1:-}"
  local target_account_id="${2:-}"
  local dev_account_id="${3:-}"
  local prod_account_id="${4:-}"

  if [[ "$environment" != "dev" && "$environment" != "prod" ]]; then
    echo "::error::environment must be dev or prod." >&2
    return 1
  fi
  if [[ ! "$target_account_id" =~ ^[0-9]{12}$ ||
        ! "$dev_account_id" =~ ^[0-9]{12}$ ||
        ! "$prod_account_id" =~ ^[0-9]{12}$ ]]; then
    echo "::error::Both CNA_AWS_TARGET_ACCOUNT_ID_DEV and CNA_AWS_TARGET_ACCOUNT_ID_PROD must be configured as 12-digit account IDs." >&2
    return 1
  fi
  if [[ "$dev_account_id" == "$prod_account_id" ]]; then
    echo "::error::Dev and prod must use distinct AWS accounts; refusing deployment or teardown." >&2
    return 1
  fi

  local registered_target
  if [[ "$environment" == "dev" ]]; then
    registered_target="$dev_account_id"
  else
    registered_target="$prod_account_id"
  fi
  if [[ "$target_account_id" != "$registered_target" ]]; then
    echo "::error::AWS_TARGET_ACCOUNT_ID does not match the registered $environment account." >&2
    return 1
  fi
}
