#!/usr/bin/env bash
#
# Decide which tags of a source image to mirror.
#
# Reads the candidate tags on stdin, one per line, and writes the selected tags
# to stdout, one per line, in the order they should be copied.
#
# Kept out of the workflow so it can be exercised against captured tag lists
# (see test-select-tags.sh); an image mirror that silently picks the wrong tags
# is not something CI notices on its own.
#
# Environment:
#   INPUT_VERSIONS   Comma-separated versions to mirror instead of the default
#                    selection. Matched with and without a leading "v".
#   ROLLING_MAJORS   Comma-separated major series whose rolling tags are always
#                    mirrored when present, e.g. "v12,v13". Default "v12,v13".
#   MIRROR_MASTER    "true" to also mirror the master tag when present.
#   MAX_RELEASES     How many discrete releases to select. Default 5.

set -euo pipefail

ROLLING_MAJORS="${ROLLING_MAJORS:-v12,v13}"
MIRROR_MASTER="${MIRROR_MASTER:-true}"
MAX_RELEASES="${MAX_RELEASES:-5}"

mapfile -t ALL_TAGS

# Tags that must never be mirrored, whatever else selects them.
#
#   sha256-*            cosign/attestation referrers, not runnable images
#   *-amd64, *-arm64    per-architecture halves published before the manifest
#                       list is merged; mirroring one makes a multi-arch tag
#                       look single-arch to consumers
#   *-nydus             lazy-loading conversion, meaningless outside its own
#                       snapshotter
#   feature-*, fix-*    branch builds
is_excluded() {
  case "$1" in
    sha256-*) return 0 ;;
    *-amd64 | *-arm64 | *-ppc64le | *-nydus) return 0 ;;
    feature-* | fix-* | dependabot-* | renovate-*) return 0 ;;
    *) return 1 ;;
  esac
}

CANDIDATES=()
for tag in ${ALL_TAGS[@]+"${ALL_TAGS[@]}"}; do
  [ -n "${tag}" ] || continue
  is_excluded "${tag}" || CANDIDATES+=("${tag}")
done

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  exit 0
fi

has_tag() {
  local needle="$1"
  local candidate
  for candidate in "${CANDIDATES[@]}"; do
    [ "${candidate}" = "${needle}" ] && return 0
  done
  return 1
}

# Newest first, ignoring an optional leading "v".
#
# `sort -V` alone is wrong here: cdxgen has published both `v12.6.0` and
# `13.0.0`, and version sort orders the letter above the digits, so every
# v-prefixed tag outranks every bare one. That silently keeps a new major out
# of the newest-N window. Sort on a stripped key and emit the original.
sort_versions_desc() {
  sed 's/^v//' | sort -V -r | while read -r stripped; do
    printf '%s\n' "${stripped}"
  done
}

# Given a version without its prefix, return whichever spelling is present.
resolve_prefix() {
  local bare="$1"
  if has_tag "${bare}"; then
    printf '%s\n' "${bare}"
  elif has_tag "v${bare}"; then
    printf 'v%s\n' "${bare}"
  fi
}

SELECTED=()
already_selected() {
  local needle="$1"
  local chosen
  for chosen in ${SELECTED[@]+"${SELECTED[@]}"}; do
    [ "${chosen}" = "${needle}" ] && return 0
  done
  return 1
}
select_tag() {
  local wanted="$1"
  already_selected "${wanted}" || SELECTED+=("${wanted}")
}

# An explicit request overrides everything else, including the exclusions
# above: asking for a tag by name is an informed choice.
if [ -n "${INPUT_VERSIONS:-}" ]; then
  IFS=',' read -ra REQUESTED <<< "${INPUT_VERSIONS}"
  for raw in "${REQUESTED[@]}"; do
    value="$(printf '%s' "${raw}" | xargs)"
    [ -n "${value}" ] || continue
    matched=""
    for tag in ${ALL_TAGS[@]+"${ALL_TAGS[@]}"}; do
      if [ "${tag}" = "${value}" ]; then
        matched="${tag}"
        break
      fi
    done
    if [ -z "${matched}" ]; then
      case "${value}" in
        v*) alternate="${value#v}" ;;
        *) alternate="v${value}" ;;
      esac
      for tag in ${ALL_TAGS[@]+"${ALL_TAGS[@]}"}; do
        if [ "${tag}" = "${alternate}" ]; then
          matched="${tag}"
          break
        fi
      done
    fi
    if [ -n "${matched}" ]; then
      select_tag "${matched}"
    else
      echo "warning: requested tag '${value}' is not present in the source" >&2
    fi
  done
  [ "${#SELECTED[@]}" -gt 0 ] && printf '%s\n' "${SELECTED[@]}"
  exit 0
fi

RELEASES=()
PRERELEASES=()
for tag in "${CANDIDATES[@]}"; do
  if [[ "${tag}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    RELEASES+=("${tag}")
  elif [[ "${tag}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+-[a-zA-Z0-9.+]+$ ]]; then
    PRERELEASES+=("${tag}")
  fi
done

# 1. The floating tag most consumers pull.
has_tag latest && select_tag latest

# 2. Rolling major and major.minor tags, selected in their own right rather
#    than derived from whichever releases happened to make the cut. These are
#    what documentation points at, so they have to keep moving even once a
#    series stops receiving releases and drops out of the newest-N window.
IFS=',' read -ra MAJORS <<< "${ROLLING_MAJORS}"
for raw_major in "${MAJORS[@]}"; do
  major="$(printf '%s' "${raw_major}" | xargs)"
  [ -n "${major}" ] || continue
  bare="${major#v}"
  for candidate in "${major}" "${bare}"; do
    has_tag "${candidate}" && select_tag "${candidate}"
  done
  # Every major.minor of that series, newest first.
  minors=()
  for tag in "${CANDIDATES[@]}"; do
    if [[ "${tag}" =~ ^v?${bare}\.[0-9]+$ ]]; then
      minors+=("${tag}")
    fi
  done
  if [ "${#minors[@]}" -gt 0 ]; then
    mapfile -t sorted_minors < <(printf '%s\n' "${minors[@]}" | sort_versions_desc)
    for stripped in "${sorted_minors[@]}"; do
      resolved="$(resolve_prefix "${stripped}")"
      [ -n "${resolved}" ] && select_tag "${resolved}"
    done
  fi
done

# 3. The newest discrete releases.
release_count=0
if [ "${#RELEASES[@]}" -gt 0 ]; then
  mapfile -t sorted_releases < <(printf '%s\n' "${RELEASES[@]}" | sort_versions_desc)
  for stripped in "${sorted_releases[@]}"; do
    [ "${release_count}" -lt "${MAX_RELEASES}" ] || break
    resolved="$(resolve_prefix "${stripped}")"
    [ -n "${resolved}" ] || continue
    already_selected "${resolved}" && continue
    select_tag "${resolved}"
    release_count=$((release_count + 1))
  done
fi

# 4. Pre-releases only when there are no releases at all, which is the state a
#    brand new major sits in between its first beta and its first GA.
if [ "${release_count}" -eq 0 ] && [ "${#PRERELEASES[@]}" -gt 0 ]; then
  mapfile -t sorted_pre < <(printf '%s\n' "${PRERELEASES[@]}" | sort_versions_desc)
  for stripped in "${sorted_pre[@]}"; do
    [ "${release_count}" -lt "${MAX_RELEASES}" ] || break
    resolved="$(resolve_prefix "${stripped}")"
    [ -n "${resolved}" ] || continue
    select_tag "${resolved}"
    release_count=$((release_count + 1))
  done
fi

# 5. The rolling development tag, last so it never displaces a release.
if [ "${MIRROR_MASTER}" = "true" ] && has_tag master; then
  select_tag master
fi

[ "${#SELECTED[@]}" -gt 0 ] && printf '%s\n' "${SELECTED[@]}"
