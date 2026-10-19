#!/bin/bash
# Prints neat release notes for the app's update dialog and the GitHub release page.
# The first line is the pull request title without its "Release vX.Y.Z:" prefix, and the
# rest are the pull request's bullet points. Other paragraphs in the description are skipped.
#
# Usage:  scripts/release-notes.sh [pull-request-number]
# Without a number it finds the pull request that produced the current commit.
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-rohitDurbha/Redfox}"
if [ -n "${1:-}" ]; then
    PR="$(gh api "repos/$REPO/pulls/$1")"
else
    PR="$(gh api "repos/$REPO/commits/$(git rev-parse HEAD)/pulls" --jq '.[0] // empty' 2>/dev/null || true)"
fi

if [ -n "$PR" ]; then
    TITLE="$(jq -r '.title' <<<"$PR" | sed -E 's/^[Rr]elease v?[0-9][0-9.]*[[:space:]]*[:-]?[[:space:]]*//')"
    BULLETS="$(jq -r '.body // ""' <<<"$PR" | tr -d '\r' \
        | grep -E '^[[:space:]]*[-*] ' \
        | sed -E 's/^[[:space:]]*[-*][[:space:]]+/• /; s/\*\*//g; s/`//g' || true)"
else
    TITLE="$(git log -1 --pretty=%s)"
    BULLETS=""
fi

[ -n "$TITLE" ] || TITLE="Bug fixes and improvements"
TITLE="$(tr '[:lower:]' '[:upper:]' <<<"${TITLE:0:1}")${TITLE:1}"

if [ -n "$BULLETS" ]; then
    printf '%s\n\n%s\n' "$TITLE" "$BULLETS"
else
    printf '%s\n' "$TITLE"
fi
