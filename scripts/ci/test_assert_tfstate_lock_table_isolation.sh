#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/assert_tfstate_lock_table_isolation.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_tfstate_lock_table_isolation dev cna-dev-lock cna-dev-lock cna-prod-lock \
  || fail "valid dev lock-table pair was rejected"
assert_tfstate_lock_table_isolation prod cna-prod-lock cna-dev-lock cna-prod-lock \
  || fail "valid prod lock-table pair was rejected"

if assert_tfstate_lock_table_isolation dev cna-shared-lock cna-shared-lock cna-shared-lock >/dev/null 2>&1; then
  fail "shared lock table was accepted"
fi
if assert_tfstate_lock_table_isolation dev cna-wrong-lock cna-dev-lock cna-prod-lock >/dev/null 2>&1; then
  fail "target lock table mismatch was accepted"
fi
if assert_tfstate_lock_table_isolation dev cna-dev-lock cna-dev-lock "" >/dev/null 2>&1; then
  fail "missing other-environment lock table was accepted"
fi

echo "All Terraform lock-table isolation regression checks passed."
