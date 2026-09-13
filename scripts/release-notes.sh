#!/usr/bin/env bash
# Release notes body for a tag: changes grouped into features / bug fixes / other, the plain
# commit list, and a thank-you line naming the commit authors. Called by scripts/make-dist.sh,
# which appends the install block; runnable by hand to preview what a release would say:
#
#   scripts/release-notes.sh v0.9.7          # what the v0.9.7 release notes say
#   scripts/release-notes.sh HEAD            # what the next release would say
#
# Grouping, first rule that applies wins:
#   1. a `bug` / `enhancement` / `documentation` label on the commit's pull request
#   2. a Conventional Commits prefix on the subject: fix:, feat:, docs:, chore:, ci:, ... (perf:
#      counts as a fix — a stall or a leak is a bug to the person hitting it)
#   3. keywords in the subject: docs/ci/tests/dead code/... -> other, fix/crash/stall/never/... ->
#      bug fix, anything else -> feature
# Label a PR or prefix a subject to override the guess; the full commit list follows the groups
# anyway, so a misfiled commit is never lost.
#
# GitHub is asked for pull-request labels and author logins through `gh api`; without `gh`, a
# token, or a network (NOTES_OFFLINE=1 to skip it on purpose) the notes are still produced, from
# git alone. A release must not fail because a lookup did.
set -euo pipefail
cd "$(dirname "$0")/.."

REF="${1:?usage: scripts/release-notes.sh <tag-or-commit>}"
REPO_SLUG="${REPO_SLUG:-tkz0/tkzmux}"
NOTES_OFFLINE="${NOTES_OFFLINE:-}"
# Author emails (ERE) left out of the thank-you line: AI-assistant and bot addresses.
RE_SKIP_AUTHOR="${NOTES_SKIP_AUTHORS:-^noreply@anthropic\.com$|\[bot\]@users\.noreply\.github\.com$}"

git rev-parse -q --verify "$REF^{commit}" >/dev/null || { echo "release-notes: unknown ref $REF" >&2; exit 1; }

# `git describe --tags --abbrev=0 REF^` fails on the very first release — there is no earlier
# tag, and if REF *is* the root commit there is no REF^ either — so `|| true` and fall back to
# the whole history. `<root>..REF` would exclude the root commit itself, and for a first release
# we want it, so the fallback range is plain `REF` (root-inclusive by definition).
PREV_TAG="$(git describe --tags --abbrev=0 --match 'v*' "$REF^" 2>/dev/null || true)"
if [[ -n "$PREV_TAG" ]]; then
  LOG_RANGE="$PREV_TAG..$REF"
  SINCE="since $PREV_TAG"
else
  LOG_RANGE="$REF"
  SINCE="(first release: everything since $(git rev-list --max-parents=0 "$REF" | tail -1 | cut -c1-7))"
fi

api_ok=0
if [[ -z "$NOTES_OFFLINE" ]] && command -v gh >/dev/null 2>&1; then api_ok=1; fi

# Labels of the pull request(s) that carried a commit, comma-separated; empty when unknown.
pr_labels() {
  ((api_ok)) || return 0
  gh api "repos/$REPO_SLUG/commits/$1/pulls" --jq '[.[].labels[].name] | join(",")' 2>/dev/null || true
}

# GitHub login for a commit author. The noreply address encodes it, which saves the round trip
# and works offline; otherwise ask GitHub about the commit; otherwise give up (empty).
author_login() {   # $1 = full sha, $2 = email
  case "$2" in
    *@users.noreply.github.com)
      local local_part="${2%%@*}"
      echo "${local_part#*+}"
      return 0 ;;
  esac
  ((api_ok)) || return 0
  gh api "repos/$REPO_SLUG/commits/$1" --jq '.author.login // empty' 2>/dev/null || true
}

# ERE word matching that does not depend on \b, which macOS's regex library lacks.
word_re() { printf '(^|[^a-z0-9])(%s)([^a-z0-9]|$)' "$1"; }
RE_PREFIX_FIX='^(fix|perf)(\([^)]*\))?!?:'
RE_PREFIX_FEAT='^feat(\([^)]*\))?!?:'
RE_PREFIX_OTHER='^(docs?|chore|ci|build|refactor|style|tests?)(\([^)]*\))?!?:'
RE_WORD_OTHER="$(word_re 'readme|docs?|documentation|contributing|changelog|ci|dead code|refactor(ing|ed)?|clean ?up|tidy|typos?|trim|bump|vendor|tests?|testing')"
RE_WORD_FIX="$(word_re 'fix|fixes|fixed|fixing|bugs?|crash(es|ed)?|stall(s|ed)?|hangs?|hung|leak(s|ed)?|regression|flicker(s|ed)?|broken|broke|wrong|never|no longer|stops?|stopped|race|deadlock|freezes?|froze|off-by-one|corrects?|properly|again')"

classify() {   # $1 = subject, $2 = PR labels -> feature | fix | other
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case ",$2," in
    *,bug,*)           echo fix;     return ;;
    *,enhancement,*)   echo feature; return ;;
    *,documentation,*) echo other;   return ;;
  esac
  if   [[ $lower =~ $RE_PREFIX_FIX   ]]; then echo fix
  elif [[ $lower =~ $RE_PREFIX_FEAT  ]]; then echo feature
  elif [[ $lower =~ $RE_PREFIX_OTHER ]]; then echo other
  elif [[ $lower =~ $RE_WORD_OTHER   ]]; then echo other
  elif [[ $lower =~ $RE_WORD_FIX     ]]; then echo fix
  else echo feature
  fi
}

# One pass over the commits: sort each into its group, and remember who wrote it. Plain files
# rather than associative arrays so /bin/bash 3.2 can run this too.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/feature"; : > "$WORK/fix"; : > "$WORK/other"; : > "$WORK/authors"

while IFS=$'\t' read -r short full name email subject; do
  [[ -n "$full" ]] || continue
  group="$(classify "$subject" "$(pr_labels "$full")")"
  printf -- '- %s (%s)\n' "$subject" "$short" >> "$WORK/$group"
  printf '%s\t%s\t%s\n' "$email" "$name" "$full" >> "$WORK/authors"
done < <(git log --no-merges --format='%h%x09%H%x09%an%x09%ae%x09%s' "$LOG_RANGE")

section() {   # $1 = heading, $2 = file
  [[ -s "$2" ]] || return 0
  echo "### $1"
  echo
  cat "$2"
  echo
}
section "New features"  "$WORK/feature"
section "Bug fixes"     "$WORK/fix"
section "Other changes" "$WORK/other"

echo "### Commits $SINCE"
echo
git log --oneline --no-decorate --no-merges "$LOG_RANGE"
echo

# ---------------------------------------------------------------------------------- thank you
# One line per distinct author email: "<count>\t<display name>", where the display name is
# @login when GitHub knows the author and the git author name otherwise. Ordered by commit
# count, then name, and joined into a sentence. The commit count in that sentence is the
# credited commits only, so it stays true when an author was skipped.
total=0
: > "$WORK/credits"
while IFS=$'\t' read -r email; do
  # A tool is not a contributor. Commits an AI assistant authored under its own noreply address
  # stay in the commit list but are not thanked; the person who drove it is credited through
  # their own commits.
  [[ $email =~ $RE_SKIP_AUTHOR ]] && continue
  count="$(awk -F'\t' -v e="$email" '$1 == e' "$WORK/authors" | wc -l | tr -d ' ')"
  IFS=$'\t' read -r name full < <(awk -F'\t' -v e="$email" '$1 == e { print $2 "\t" $3; exit }' "$WORK/authors")
  login="$(author_login "$full" "$email")"
  if [[ -n "$login" ]]; then display="@$login"; else display="$name"; fi
  printf '%s\t%s\n' "$count" "$display" >> "$WORK/credits"
  total=$((total + count))
done < <(cut -f1 "$WORK/authors" | sort -u)

if [[ -s "$WORK/credits" ]]; then
  names=()
  while IFS=$'\t' read -r _ display; do names+=("$display"); done \
    < <(sort -t$'\t' -k1,1nr -k2,2 "$WORK/credits")
  n=${#names[@]}
  if   ((n == 1)); then who="${names[0]}"
  elif ((n == 2)); then who="${names[0]} and ${names[1]}"
  else
    who="$(printf '%s, ' "${names[@]:0:n-1}")and ${names[n-1]}"
  fi
  commits="commits"; ((total == 1)) && commits="commit"
  echo "### Thank you"
  echo
  echo "Thanks to $who for the $total $commits in this release."
fi
