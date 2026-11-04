#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/assert_distinct_aws_accounts.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_distinct_aws_accounts dev 111111111111 111111111111 222222222222 \
  || fail "valid dev account pair was rejected"
assert_distinct_aws_accounts prod 222222222222 111111111111 222222222222 \
  || fail "valid prod account pair was rejected"

if assert_distinct_aws_accounts dev 111111111111 111111111111 111111111111 >/dev/null 2>&1; then
  fail "shared dev/prod account was accepted"
fi
if assert_distinct_aws_accounts dev 333333333333 111111111111 222222222222 >/dev/null 2>&1; then
  fail "target account mismatch was accepted"
fi
if assert_distinct_aws_accounts prod 222222222222 111111111111 "" >/dev/null 2>&1; then
  fail "missing prod account registration was accepted"
fi
if assert_distinct_aws_accounts staging 111111111111 111111111111 222222222222 >/dev/null 2>&1; then
  fail "unsupported environment was accepted"
fi

echo "All distinct AWS account regression checks passed."
