#!/bin/sh
# check-public.sh - refuse to commit anything that looks private. This is a PUBLIC repo.
# Checks the staged files for secrets, credential/env files and personal identifiers.
#   Install as a pre-commit hook:  git config core.hooksPath tools/hooks
#   Extra personal words (usernames, project names) go in .git/private-words, one per line;
#   that file stays local and is never committed.
fail=0
# The pattern list below would match itself, so this file is not scanned for content.
self=':(exclude)tools/check-public.sh'
staged=$(git diff --cached --name-only --diff-filter=ACMR)
[ -n "$staged" ] || exit 0

bad_names=$(printf '%s\n' "$staged" | grep -i -E '(^|/)\.env($|\.)|\.pem$|\.key$|\.pfx$|\.p12$|id_rsa|credential|secret|\.jsonl$|(^|/)settings\.json$|(^|/)projects\.json$|\.log$' | grep -v -E '\.env\.example$')
if [ -n "$bad_names" ]; then echo "check-public: refusing private-looking files:"; echo "$bad_names"; fail=1; fi

secrets='sk-ant-|ghp_[A-Za-z0-9]{20}|github_pat_|gho_[A-Za-z0-9]{20}|AKIA[0-9A-Z]{16}|xox[bpa]-|BEGIN [A-Z ]*PRIVATE KEY|AIza[0-9A-Za-z_-]{30}'
if git diff --cached -U0 -- . "$self" | grep -E '^\+' | grep -E -q "$secrets"; then
    echo "check-public: a staged change contains something that looks like a secret/API key."; fail=1
fi

words="$(git rev-parse --git-dir)/private-words"
if [ -f "$words" ]; then
    hits=$(git diff --cached -U0 -- . "$self" | grep -E '^\+' | grep -i -F -f "$words")
    if [ -n "$hits" ]; then echo "check-public: staged changes contain private words (.git/private-words):"; echo "$hits" | head -5; fail=1; fi
fi

[ $fail -eq 0 ] || echo "check-public: commit blocked. Remove the items above (or unstage them)."
exit $fail
