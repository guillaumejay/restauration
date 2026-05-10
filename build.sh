#!/usr/bin/env bash
# pairs2web — build script
# Scans pairs/ and generates public/pairs.json + copies images.
# Designed to run as-is on Vercel and Cloudflare Pages build containers.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAIRS_DIR="${ROOT_DIR}/pairs"
PUBLIC_DIR="${ROOT_DIR}/public"
OUT_PAIRS_DIR="${PUBLIC_DIR}/pairs"
MANIFEST="${PUBLIC_DIR}/pairs.json"

echo "▶ pairs2web build"
echo "  pairs source : ${PAIRS_DIR}"
echo "  output       : ${PUBLIC_DIR}"

if [[ ! -d "${PAIRS_DIR}" ]]; then
  echo "✗ no pairs/ directory found" >&2
  exit 1
fi

# Clean previous build output (but keep index.html, assets, etc.)
rm -rf "${OUT_PAIRS_DIR}"
mkdir -p "${OUT_PAIRS_DIR}"

# Detect optional tools
HAS_JQ=0
command -v jq >/dev/null 2>&1 && HAS_JQ=1

# Find any image with one of the supported extensions matching a base name
# Usage: find_image <dir> <basename>
find_image() {
  local dir="$1"
  local base="$2"
  local ext
  for ext in jpg jpeg png webp avif gif JPG JPEG PNG WEBP AVIF GIF; do
    if [[ -f "${dir}/${base}.${ext}" ]]; then
      echo "${base}.${ext}"
      return 0
    fi
  done
  return 1
}

# Read a key from a simple `key: value` meta.txt file
# Usage: meta_get <file> <key>
meta_get() {
  local file="$1"
  local key="$2"
  if [[ -f "${file}" ]]; then
    # `grep || true` so a missing key (exit 1) doesn't abort the script under `set -e`.
    { grep -E "^${key}[[:space:]]*:" "${file}" || true; } \
      | head -n1 \
      | sed -E "s/^${key}[[:space:]]*:[[:space:]]*//" \
      | sed 's/[[:space:]]*$//'
  fi
}

# JSON string escape (handles ", \, newlines, tabs, control chars)
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Optional site-level intro (HTML), read from pairs/intro.html
INTRO_FILE="${PAIRS_DIR}/intro.html"
intro_html=""
if [[ -f "${INTRO_FILE}" ]]; then
  intro_html="$(cat "${INTRO_FILE}")"
  echo "  ✓ intro: ${INTRO_FILE}"
fi

# Build manifest entries
entries=()
count=0
skipped=0

# Iterate sub-directories of pairs/ in sorted order so the order on disk
# determines the order on the site.
shopt -s nullglob
for dir in "${PAIRS_DIR}"/*/; do
  slug="$(basename "${dir}")"
  # Skip hidden / underscore-prefixed dirs
  [[ "${slug}" == .* || "${slug}" == _* ]] && continue

  before_file="$(find_image "${dir}" "before" || true)"
  after_file="$(find_image "${dir}" "after" || true)"

  if [[ -z "${before_file}" || -z "${after_file}" ]]; then
    echo "  ⚠ skipping '${slug}' (need both before.* and after.*)"
    skipped=$((skipped + 1))
    continue
  fi

  meta_file="${dir}meta.txt"
  title="$(meta_get "${meta_file}" "title")"
  description="$(meta_get "${meta_file}" "description")"
  date="$(meta_get "${meta_file}" "date")"
  before_label="$(meta_get "${meta_file}" "before_label")"
  after_label="$(meta_get "${meta_file}" "after_label")"

  # Sensible defaults
  [[ -z "${title}" ]] && title="$(echo "${slug}" | sed -E 's/^[0-9]+[-_]*//; s/[-_]/ /g' | sed -E 's/\b(.)/\U\1/g')"
  [[ -z "${before_label}" ]] && before_label="Before"
  [[ -z "${after_label}" ]] && after_label="After"

  # Copy images to public/pairs/<slug>/
  mkdir -p "${OUT_PAIRS_DIR}/${slug}"
  cp "${dir}${before_file}" "${OUT_PAIRS_DIR}/${slug}/${before_file}"
  cp "${dir}${after_file}"  "${OUT_PAIRS_DIR}/${slug}/${after_file}"

  # Build a JSON object for this entry — emit optional fields only when set
  fields=()
  fields+=("  \"slug\": \"$(json_escape "${slug}")\"")
  fields+=("  \"title\": \"$(json_escape "${title}")\"")
  [[ -n "${description}" ]] && fields+=("  \"description\": \"$(json_escape "${description}")\"")
  [[ -n "${date}" ]]        && fields+=("  \"date\": \"$(json_escape "${date}")\"")
  fields+=("  \"before\": \"pairs/${slug}/${before_file}\"")
  fields+=("  \"after\": \"pairs/${slug}/${after_file}\"")
  fields+=("  \"before_label\": \"$(json_escape "${before_label}")\"")
  fields+=("  \"after_label\": \"$(json_escape "${after_label}")\"")

  entry="{"$'\n'
  for j in "${!fields[@]}"; do
    sep=","
    [[ $j -eq $((${#fields[@]} - 1)) ]] && sep=""
    entry+="${fields[$j]}${sep}"$'\n'
  done
  entry+="}"
  entries+=("${entry}")
  count=$((count + 1))
  echo "  ✓ ${slug}  (${before_file} → ${after_file})"
done
shopt -u nullglob

# Assemble final JSON
{
  echo "{"
  echo "  \"generated_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  if [[ -n "${intro_html}" ]]; then
    echo "  \"intro\": \"$(json_escape "${intro_html}")\","
  fi
  echo "  \"count\": ${count},"
  echo "  \"pairs\": ["
  for i in "${!entries[@]}"; do
    sep=","
    [[ $i -eq $((${#entries[@]} - 1)) ]] && sep=""
    # Indent each entry by 4 spaces
    echo "${entries[$i]}" | sed 's/^/    /' | sed '$s/$/'"${sep}"'/'
  done
  echo "  ]"
  echo "}"
} > "${MANIFEST}"

# Validate JSON if jq is available
if [[ ${HAS_JQ} -eq 1 ]]; then
  jq empty "${MANIFEST}" >/dev/null 2>&1 || {
    echo "✗ generated manifest is invalid JSON" >&2
    exit 1
  }
fi

echo ""
echo "▶ done — ${count} pair(s) built, ${skipped} skipped"
echo "  manifest: ${MANIFEST}"
