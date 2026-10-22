#!/usr/bin/env bash
# Print one version's block from CHANGELOG.md, without its "## [x.y.z]"
# heading, for the GitHub release body.
#
#   scripts/release-notes.sh 2.2.8          # or v2.2.8
#
# Fails when CHANGELOG.md has no block for that version, or the block is
# empty, so the release workflow can stop before anything is published.
set -euo pipefail

version="${1:?usage: scripts/release-notes.sh <version>}"
version="${version#v}"
changelog="$(dirname "$0")/../CHANGELOG.md"

notes=$(awk -v v="$version" '
    index($0, "## [" v "]") == 1 { found = 1; next }
    found && /^## \[/ { exit }
    found { print }
' "$changelog")

# Drop the blank lines left at either end.
notes=$(printf '%s\n' "$notes" | sed -e '/./,$!d')
notes=$(printf '%s' "$notes")

if [[ -z "$notes" ]]; then
    echo "CHANGELOG.md has no notes for $version." >&2
    exit 1
fi
printf '%s\n' "$notes"
