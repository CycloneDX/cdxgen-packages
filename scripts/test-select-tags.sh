#!/usr/bin/env bash
#
# Exercise select-tags.sh against captured and synthetic tag lists.
#
#   ./scripts/test-select-tags.sh
#
# The fixtures under fixtures/ are real `skopeo list-tags` output. Refresh them
# with:
#   skopeo list-tags docker://ghcr.io/cdxgen/cdxgen | jq -r '.Tags[]' \
#     > scripts/fixtures/cdxgen-tags.txt

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECT="${HERE}/select-tags.sh"
FIXTURES="${HERE}/fixtures"

failures=0
checks=0

# check <name> <tags-file> <expected-newline-separated> [env assignments...]
check() {
  local name="$1" tags_file="$2" expected="$3"
  shift 3
  local actual
  actual="$(env "$@" "${SELECT}" < "${tags_file}" 2>/dev/null)"
  checks=$((checks + 1))
  if [ "${actual}" = "${expected}" ]; then
    printf 'ok   %s\n' "${name}"
  else
    failures=$((failures + 1))
    printf 'FAIL %s\n' "${name}"
    printf '     expected: %s\n' "$(printf '%s' "${expected}" | tr '\n' ' ')"
    printf '     actual:   %s\n' "$(printf '%s' "${actual}" | tr '\n' ' ')"
  fi
}

check_contains() {
  local name="$1" tags_file="$2" needle="$3"
  shift 3
  local actual
  actual="$(env "$@" "${SELECT}" < "${tags_file}" 2>/dev/null)"
  checks=$((checks + 1))
  if printf '%s\n' "${actual}" | grep -qx "${needle}"; then
    printf 'ok   %s\n' "${name}"
  else
    failures=$((failures + 1))
    printf 'FAIL %s (missing %s)\n' "${name}" "${needle}"
    printf '     actual: %s\n' "$(printf '%s' "${actual}" | tr '\n' ' ')"
  fi
}

check_excludes() {
  local name="$1" tags_file="$2" needle="$3"
  shift 3
  local actual
  actual="$(env "$@" "${SELECT}" < "${tags_file}" 2>/dev/null)"
  checks=$((checks + 1))
  if printf '%s\n' "${actual}" | grep -qx "${needle}"; then
    failures=$((failures + 1))
    printf 'FAIL %s (should not mirror %s)\n' "${name}" "${needle}"
  else
    printf 'ok   %s\n' "${name}"
  fi
}

# --- the release this repo exists to carry forward -------------------------

check_contains "v13 rolling tag is mirrored" \
  "${FIXTURES}/cdxgen-v13-tags.txt" "v13"
check_contains "v13.0 rolling tag is mirrored" \
  "${FIXTURES}/cdxgen-v13-tags.txt" "v13.0"
check_contains "13.0.0 release is mirrored" \
  "${FIXTURES}/cdxgen-v13-tags.txt" "13.0.0"
check_contains "v12 stays current after v13 ships" \
  "${FIXTURES}/cdxgen-v13-tags.txt" "v12"

# --- tags that must never reach the mirror ---------------------------------

check_excludes "per-arch halves are not mirrored" \
  "${FIXTURES}/cdxgen-v13-tags.txt" "13.0.0-amd64"
check_excludes "attestation referrers are not mirrored" \
  "${FIXTURES}/cdxgen-tags.txt" \
  "sha256-8594e5fabf981fc27c3b8070340ddbc0e51fcaa21a4b52184e59203ae9582c1a"
check_excludes "branch builds are not mirrored" \
  "${FIXTURES}/cdxgen-tags.txt" "feature-ruby4"
check_excludes "nydus conversions are not mirrored" \
  "${FIXTURES}/cdxgen-tags.txt" "master-nydus"

# --- ordering and shape ----------------------------------------------------

check "small list selects in priority order" \
  "${FIXTURES}/small.txt" \
  "$(printf 'latest\nv12\nv12.6\n12.7.0\nmaster')"

check "master can be turned off" \
  "${FIXTURES}/small.txt" \
  "$(printf 'latest\nv12\nv12.6\n12.7.0')" \
  MIRROR_MASTER=false

check "explicit versions override the default selection" \
  "${FIXTURES}/cdxgen-v13-tags.txt" \
  "$(printf '13.0.0\n12.7.0')" \
  INPUT_VERSIONS="13.0.0, 12.7.0"

check "a requested tag that does not exist is skipped, not fatal" \
  "${FIXTURES}/small.txt" \
  "12.7.0" \
  INPUT_VERSIONS="12.7.0,99.99.99"

check "a series with only pre-releases still mirrors something" \
  "${FIXTURES}/prerelease-only.txt" \
  "$(printf 'v14.0.0-beta.2\nv14.0.0-beta.1')" \
  ROLLING_MAJORS=v14

check "empty input produces no output" \
  "${FIXTURES}/empty.txt" ""

check "an image with only excluded tags produces no output" \
  "${FIXTURES}/excluded-only.txt" ""

check "tags that match no category produce no output" \
  "${FIXTURES}/no-match.txt" ""

check "explicit versions matching nothing produce no output" \
  "${FIXTURES}/no-match.txt" "" \
  INPUT_VERSIONS="99.99.99"

printf '\n%d checks, %d failures\n' "${checks}" "${failures}"
[ "${failures}" -eq 0 ]
