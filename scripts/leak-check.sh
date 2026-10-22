#!/usr/bin/env bash
# leak-check.sh — block commits/pushes that leak private info.
#
#   scripts/leak-check.sh            scan all tracked + staged files
#   scripts/leak-check.sh --staged   scan staged content only (pre-commit)
#
# Two layers:
#   1. Built-in generic rules (absolute home paths, emails, keys, tokens)
#   2. Private denylist, kept OUTSIDE the repo so the sensitive words
#      themselves are never published:
#        $KIRO_PURE_DENYLIST  (default: ~/.config/kiro-pure/denylist.txt)
#      One case-insensitive ERE per line; '#' comments allowed.
#
# Paths listed in .leakcheck-ignore (one shell glob per line, '#' comments)
# are skipped — use only for vendored / third-party / legacy-public files.
# Binary files are always skipped.
#
# Exit 0 = clean, 1 = leak found, 2 = setup error.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "leak-check: not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2

DENY="${KIRO_PURE_DENYLIST:-$HOME/.config/kiro-pure/denylist.txt}"
MODE="all"; [ "${1:-}" = "--staged" ] && MODE="staged"

# Built-in rules: label<TAB>regex
BUILTIN=$(cat <<'EOF'
abs-home-path	(/home/[a-z0-9_.-]+/|/Users/[A-Za-z0-9_.-]+/)
email	[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}
private-key	-----BEGIN [A-Z ]*PRIVATE KEY-----
aws-key	AKIA[0-9A-Z]{16}
github-token	gh[pousr]_[A-Za-z0-9]{30,}
gitlab-token	glpat-[A-Za-z0-9_-]{20,}
generic-secret	(api[_-]?key|secret|password|passwd|token)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"'$<{ ]{8,}
EOF
)

# Allowed placeholder emails / paths
ALLOW='(you@example\.com|user@example\.com|git@github\.com|[A-Za-z0-9._-]+@host)'

if [ "$MODE" = "staged" ]; then
    FILES=$(git diff --cached --name-only --diff-filter=ACMR)
else
    FILES=$( { git ls-files; git diff --cached --name-only --diff-filter=ACMR; } | sort -u)
fi
[ -z "$FILES" ] && { echo "leak-check: nothing to scan"; exit 0; }

IGNORE_GLOBS=()
if [ -f .leakcheck-ignore ]; then
    while IFS= read -r g || [ -n "$g" ]; do
        g="${g%%#*}"; g="${g#"${g%%[![:space:]]*}"}"; g="${g%"${g##*[![:space:]]}"}"
        [ -n "$g" ] && IGNORE_GLOBS+=("$g")
    done < .leakcheck-ignore
fi
ignored() {
    local g
    for g in "${IGNORE_GLOBS[@]}"; do
        # shellcheck disable=SC2053
        [[ "$1" == $g ]] && return 0
    done
    return 1
}
is_binary() {  # grep -I treats binary as non-matching → no text line = binary/empty
    if [ "$MODE" = "staged" ]; then ! git show ":$1" 2>/dev/null | head -c 8000 | LC_ALL=C grep -qI .
    else ! head -c 8000 "$1" 2>/dev/null | LC_ALL=C grep -qI .; fi
}

content() {  # staged blob in staged mode, working copy otherwise
    if [ "$MODE" = "staged" ]; then git show ":$1" 2>/dev/null; else cat "$1" 2>/dev/null; fi
}

hits=0
report() { echo "  [$1] $2:$3"; hits=$((hits+1)); }

while IFS= read -r f; do
    [ -f "$f" ] || [ "$MODE" = "staged" ] || continue
    case "$f" in scripts/leak-check.sh|.leakcheck-ignore) continue ;; esac   # rules live here
    ignored "$f" && continue
    is_binary "$f" && continue
    body="$(content "$f")"
    [ -z "$body" ] && continue

    while IFS=$'\t' read -r label re; do
        [ -z "$label" ] && continue
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            text="${line#*:}"
            # ignore matches that are only allowed placeholders
            printf '%s' "$text" | sed -E "s/$ALLOW//gI" | grep -qiE -e "$re" || continue
            report "$label" "$f" "${line%%:*}"
        done < <(printf '%s\n' "$body" | grep -niE -e "$re")
    done <<< "$BUILTIN"

    if [ -f "$DENY" ]; then
        while IFS= read -r re || [ -n "$re" ]; do
            re="${re%%#*}"                                   # strip comment
            re="${re#"${re%%[![:space:]]*}"}"; re="${re%"${re##*[![:space:]]}"}"  # trim (keeps backslashes)
            [ -z "$re" ] && continue
            while IFS= read -r ln; do
                report "denylist" "$f" "$ln"   # don't echo the matched word
            done < <(printf '%s\n' "$body" | grep -niE -- "$re" | cut -d: -f1)
            # also check the file path itself
            printf '%s' "$f" | grep -qiE -- "$re" && report "denylist-path" "$f" 0
        done < "$DENY"
    fi
done <<< "$FILES"

if [ ! -f "$DENY" ]; then
    echo "leak-check: WARNING private denylist not found ($DENY) — only built-in rules ran" >&2
fi

if [ "$hits" -gt 0 ]; then
    echo "leak-check: ✗ $hits potential leak(s) — fix or adjust before committing" >&2
    exit 1
fi
echo "leak-check: ✓ clean ($(echo "$FILES" | wc -l) files, mode=$MODE)"
