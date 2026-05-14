#!/usr/bin/env bash
# rewrite-history-redact.sh - one-shot git history scrubber for leaked secrets.
#
# Designed for the case where a credential was committed and pushed to
# `origin/main`, then deleted in a follow-up commit. The deletion does NOT
# remove the value from history; this script does.
#
# Usage:
#   bash scripts/rewrite-history-redact.sh <redactions-file> <empty-work-dir>
#   bash scripts/rewrite-history-redact.sh --help
#
# Arguments:
#   <redactions-file>   Absolute path to a `git filter-repo --replace-text`
#                       expressions file. Must NOT live inside any clone of
#                       this repo (the script refuses paths under
#                       /Volumes/docker/ce-stacks or /volume2/docker/ce-stacks).
#                       Recommended location: /tmp/ce-stacks-redactions.txt
#                       Format (one entry per line, literal substring):
#                         <secret-value>==>REDACTED_PLACEHOLDER
#                       Example (never commit real values):
#                         YOUR_SUBSTRING_HERE==>REDACTED_PLACEHOLDER
#
#   <empty-work-dir>    Absolute path to an empty (or non-existent) working
#                       directory. The script does ALL of its work here so
#                       your live `/Volumes/docker/ce-stacks` and the NAS clone
#                       at `/volume2/docker/ce-stacks` are never touched.
#                       Recommended: /tmp/ce-stacks-history-rewrite
#
# Prerequisites:
#   - `git-filter-repo` installed and on PATH.
#       macOS:   brew install git-filter-repo
#       Linux:   pipx install git-filter-repo  (or distro package)
#   - The leaked credential has ALREADY BEEN ROTATED at every place that
#     trusted it. History rewrite alone cannot un-leak a value that was
#     ever pushed to a public remote - assume scrapers and forks already
#     have it.
#   - You are running this from a machine that has a clean workspace
#     OUTSIDE both `/Volumes/docker/ce-stacks` and `/volume2/docker/ce-stacks`.
#     The script will clone the remote fresh into <empty-work-dir>.
#
# What this script does:
#   1. Validates inputs and toolchain.
#   2. `git clone --mirror git@github.com:ofayese/ce-stacks.git`
#      into <empty-work-dir>/ce-stacks.git
#   3. Sanity-checks that at least one source pattern from the redactions
#      file is currently reachable somewhere in history.
#   4. Runs `git filter-repo --replace-text <redactions-file>`.
#   5. Re-checks that NO source pattern remains anywhere in history.
#   6. Prints, but does NOT execute, the exact `git push --force-with-lease`
#      command and the post-push recovery procedure.
#
# What this script deliberately does NOT do:
#   - It does NOT force-push. You force-push only after reviewing the diff.
#   - It does NOT mutate your active workspace clone or the NAS clone.
#     After force-push, both must be re-cloned (their old history is gone).
#   - It does NOT delete the redactions file. After a successful rewrite,
#     securely remove it yourself:
#         macOS:  rm -P <redactions-file>
#         Linux:  shred -u <redactions-file>
#
# References:
#   - https://github.com/newren/git-filter-repo
#   - GitHub: "Removing sensitive data from a repository"

set -euo pipefail

REMOTE_URL="git@github.com:ofayese/ce-stacks.git"
FORBIDDEN_PREFIXES=(
	"/Volumes/docker/ce-stacks"
	"/volume2/docker/ce-stacks"
)

usage() {
	sed -n '2,/^set -euo pipefail$/p' "$0" | sed 's/^# \{0,1\}//;$d'
}

die() {
	printf 'rewrite-history-redact: error: %s\n' "$*" >&2
	exit 1
}

require_outside_repo_clones() {
	local path=$1 label=$2
	for prefix in "${FORBIDDEN_PREFIXES[@]}"; do
		case "$path" in
		"$prefix" | "$prefix"/*)
			die "$label ($path) lives under $prefix; choose a path outside every clone of this repo (e.g. under /tmp)."
			;;
		esac
	done
}

[[ ${1:-} == "--help" || ${1:-} == "-h" ]] && {
	usage
	exit 0
}

brief_usage() {
	cat <<'BRIEF' >&2
rewrite-history-redact: missing arguments - pass exactly two paths.

  bash scripts/rewrite-history-redact.sh <absolute-redactions-file> <absolute-empty-work-dir>

Both paths must be OUTSIDE this repo (not under /volume2/docker/ce-stacks or /Volumes/docker/ce-stacks).

Example on DSM / Linux (creates /tmp redactions file with one literal substring to replace):

  printf '%s\n' 'YOUR_SECRET_SUBSTRING==>REDACTED_PLACEHOLDER' >/tmp/ce-stacks-redactions.txt
  bash scripts/rewrite-history-redact.sh /tmp/ce-stacks-redactions.txt /tmp/ce-stacks-history-rewrite

Use your real leaked substring on the left of ==> (never commit it). Prefer running as your normal
user so SSH keys work for git@github.com; sudo runs as root and often breaks clone auth.

Full manual: bash scripts/rewrite-history-redact.sh --help
BRIEF
}

[[ $# -eq 2 ]] || {
	brief_usage
	exit 1
}

REDACTIONS_FILE=$1
WORK_DIR=$2

[[ "$REDACTIONS_FILE" = /* ]] || die "redactions file must be an absolute path: $REDACTIONS_FILE"
[[ "$WORK_DIR" = /* ]] || die "work dir must be an absolute path: $WORK_DIR"

require_outside_repo_clones "$REDACTIONS_FILE" "redactions file"
require_outside_repo_clones "$WORK_DIR" "work dir"

[[ -f "$REDACTIONS_FILE" ]] || die "redactions file not found: $REDACTIONS_FILE"
[[ -s "$REDACTIONS_FILE" ]] || die "redactions file is empty: $REDACTIONS_FILE"
grep -q '==>' "$REDACTIONS_FILE" || die "redactions file has no '<value>==>REPLACEMENT' lines"

if [[ -e "$WORK_DIR" ]]; then
	if [[ -d "$WORK_DIR" ]]; then
		[[ -z "$(ls -A "$WORK_DIR")" ]] || die "work dir exists and is not empty: $WORK_DIR"
	else
		die "work dir path exists and is not a directory: $WORK_DIR"
	fi
fi

command -v git >/dev/null || die "git not on PATH"
command -v git-filter-repo >/dev/null || die "git-filter-repo not on PATH (install: brew install git-filter-repo OR pipx install git-filter-repo)"

mkdir -p "$WORK_DIR"

MIRROR_DIR="$WORK_DIR/ce-stacks.git"

printf '\n[1/5] Mirror-cloning %s into %s ...\n' "$REMOTE_URL" "$MIRROR_DIR"
git clone --mirror "$REMOTE_URL" "$MIRROR_DIR"

cd "$MIRROR_DIR"

printf '\n[2/5] Confirming at least one redaction pattern is currently reachable in history ...\n'
mapfile -t PATTERNS < <(awk -F'==>' 'NF>=2 && length($1)>0 {print $1}' "$REDACTIONS_FILE")
[[ ${#PATTERNS[@]} -gt 0 ]] || die "no usable patterns parsed from $REDACTIONS_FILE"

found_any=0
for pat in "${PATTERNS[@]}"; do
	hit_count=$(git grep -I --all -F -l "$pat" -- "$(git rev-list --all)" 2>/dev/null | wc -l | tr -d ' ' || true)
	if [[ "${hit_count:-0}" -gt 0 ]]; then
		printf '  - found pattern in %s blob(s)\n' "$hit_count"
		found_any=1
	else
		printf '  - WARNING: pattern not currently reachable in history (already redacted?): %s\n' "${pat:0:8}…"
	fi
done

if [[ "$found_any" -eq 0 ]]; then
	printf '\nNo redactions to apply - every pattern is already absent from history. Nothing to do.\n'
	exit 0
fi

printf '\n[3/5] Running git filter-repo --replace-text %s ...\n' "$REDACTIONS_FILE"
git filter-repo --replace-text "$REDACTIONS_FILE"

printf '\n[4/5] Verifying no redaction pattern remains in any reachable blob ...\n'
remaining=0
for pat in "${PATTERNS[@]}"; do
	hit_count=$(git grep -I --all -F -l "$pat" -- "$(git rev-list --all)" 2>/dev/null | wc -l | tr -d ' ' || true)
	if [[ "${hit_count:-0}" -gt 0 ]]; then
		printf '  - STILL PRESENT in %s blob(s) - pattern starts with: %s\n' "$hit_count" "${pat:0:8}…"
		remaining=$((remaining + 1))
	fi
done
[[ "$remaining" -eq 0 ]] || die "rewrite incomplete; $remaining pattern(s) still reachable. Do NOT push."

printf '\n[5/5] Rewrite complete. Mirror is ready for force-push.\n'

cat <<EOF

NEXT STEPS - review, then execute these manually:

  1. Inspect the rewritten history (optional but recommended):
       cd $MIRROR_DIR
       git log --oneline -n 20
       git show <suspect-commit> -- stacks/code-server/config/code-server/config.yaml || true

  2. Restore the origin remote and force-push the rewritten refs.
     filter-repo strips remotes by design; add it back here:
       cd $MIRROR_DIR
       git remote add origin $REMOTE_URL
       git push --force-with-lease --mirror origin

     --mirror pushes ALL refs (branches AND tags). If you want to be
     more conservative, push branches one at a time instead.

  3. After force-push succeeds, every existing clone has stale history.
     Re-clone the workspace and the NAS:

       # Local workspace (macOS):
       cd /Volumes/docker
       mv ce-stacks ce-stacks.pre-rewrite.\$(date +%Y%m%d)
       git clone $REMOTE_URL ce-stacks

       # NAS (over SSH):
       ssh laolufayese@10.0.1.15 -p 28
       cd /volume2/docker
       sudo mv ce-stacks ce-stacks.pre-rewrite.\$(date +%Y%m%d)
       sudo git clone $REMOTE_URL ce-stacks
       sudo bash ce-stacks/scripts/init-nas.sh

  4. Open PRs / branches that contained the rewritten commits will need
     to be rebased onto the new history (or closed and re-opened).
     GitHub may also keep the old commits visible via direct SHA URLs
     for some time - they are unreachable from refs but cached.

  5. Securely delete your local redactions file:
       macOS:  rm -P $REDACTIONS_FILE
       Linux:  shred -u $REDACTIONS_FILE

  6. Treat the original credential as permanently compromised (it has
     been public on GitHub since the original push). Confirm rotation
     was actually applied wherever it was used.
EOF
