#!/usr/bin/env bash
#
# Sync skills from the single source (.agents/skills) into each agent's
# skills directory, using COPY (not symlinks) so every agent sees a
# standalone tree even if it resolves symlinks poorly.
#
# This script and the source (.agents/skills) are committed to git, so the
# whole skill distribution travels with the repo. Run it on any checkout
# (or CI/bootstrap step) to propagate skills to each configured agent.
#
# Conflict handling:
#   A "conflict" is a skill that exists in a target dir but NOT in the
#   source (it would otherwise be deleted). When one or more conflicts are
#   found, the script stops and asks the operator to pick ONE action for the
#   whole batch:
#     overwrite  -> delete the conflicting skills from that target
#     absorb     -> copy the conflicting skill into .agents/skills (new
#                   authority), then distribute it to every target
#     cancel     -> do nothing, leave everything untouched (default)
#
# In a non-interactive environment (no TTY) the default is "cancel", so it
# is safe to run in CI. Pass --yes to force "overwrite" without prompting.
#
# Usage:
#   .agents/scripts/sync-skills.sh                 # sync all configured targets
#   .agents/scripts/sync-skills.sh --dry-run       # preview without writing
#   .agents/scripts/sync-skills.sh --targets=a,b,c # override target list
#   .agents/scripts/sync-skills.sh --force         # create missing targets
#   .agents/scripts/sync-skills.sh --yes           # auto-overwrite conflicts
#
set -euo pipefail

# Resolve repo root (parent of this script's .agents dir).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SOURCE_DIR="${REPO_ROOT}/.agents/skills"

# ---------------------------------------------------------------------------
# Configure which agent skills dirs to sync into.
#
# Relative to REPO_ROOT (e.g. `docs` is fine), or absolute paths are accepted.
# A target is skipped if its directory does not exist, unless you pass
# --force (which creates missing dirs).
# ---------------------------------------------------------------------------
TARGETS=(
  # Repo-local agent skills dirs (committed / expected inside the checkout)
  ".acecode/skills"
  ".claude/skills"
  ".codex/skills"
)

# Skills that exist ONLY inside a specific target (not in the source) and
# must be treated as "preserved" (never listed as a conflict, never cleaned).
# Key = target dir (caller-provided relative form), value = space separated
# skill names. Usually empty: .agents/skills is the single source of truth.
declare -A PRESERVE

DRY_RUN=0
FORCE=0
YES=0
TARGET_OVERRIDE=""

usage() {
  sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    --yes)     YES=1 ;;
    --targets=*) TARGET_OVERRIDE="${arg#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

is_tty() { [ -t 0 ] && [ -t 1 ]; }

abs_target() {
  local t="$1"
  if [[ "$t" == ./* ]] || [[ "$t" != /* ]]; then
    printf '%s' "${REPO_ROOT}/${t}"
  else
    printf '%s' "$t"
  fi
}

log() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------------------
if [ ! -d "$SOURCE_DIR" ]; then
  echo "error: source skills dir not found: $SOURCE_DIR" >&2
  exit 1
fi

# Map of skill name -> directory inside SOURCE_DIR.
declare -A SKILLS
for skill_dir in "${SOURCE_DIR}"/*/; do
  [ -d "$skill_dir" ] || continue
  SKILLS["$(basename "$skill_dir")"]="$skill_dir"
done

if [ -n "$TARGET_OVERRIDE" ]; then
  IFS=',' read -r -a TARGETS <<< "$TARGET_OVERRIDE"
fi

# ---------------------------------------------------------------------------
# Environment for the sync.
# kind: sync -> reachable copy sync
# kind: dry  -> report only
env_kind="sync"
if [ "$DRY_RUN" -eq 1 ]; then
  env_kind="dry"
fi

copy_one() { # src dst  -> copies ensuring dst==src
  local src="$1" dst="$2"
  if [ "$env_kind" = "dry" ]; then
    log "  (copy) $(basename "$dst")"
    return
  fi
  rm -rf "$dst"
  mkdir -p "$dst"
  cp -a "$src"/. "$dst"/
  log "  (copy) $(basename "$dst")"
}

clean_one() { # target_dir name -> remove skill dir
  local target_dir="$1" name="$2"
  if [ "$env_kind" = "dry" ]; then
    log "  (clean) $name"
    return
  fi
  rm -rf "$target_dir/$name"
  log "  (clean) $name"
}

# ---------------------------------------------------------------------------
# Stage 1: copy all source skills into every target.
# ---------------------------------------------------------------------------
sync_copy_stage() {
  local t abs
  for t in "${TARGETS[@]}"; do
    abs="$(abs_target "$t")"
    if [ ! -d "$abs" ]; then
      if [ "$FORCE" -eq 1 ]; then
        if [ "$env_kind" = "dry" ]; then
          log "  (mkdir) $t"
        else
          mkdir -p "$abs"
          log "  (mkdir) $t"
        fi
      else
        log "  skip (does not exist, use --force to create): $t"
        continue
      fi
    fi
    local skill
    for skill in "${!SKILLS[@]}"; do
      copy_one "${SOURCE_DIR}/${skill}" "${abs}/${skill}"
    done
  done
}

# ---------------------------------------------------------------------------
# Stage 2: detect conflicts (target-only skills that are not preserved).
# ---------------------------------------------------------------------------
declare -a CONFLICTS_PATHS=()   # "target_abs|skill"
gather_conflicts() {
  CONFLICTS_PATHS=()
  local t abs preserved existing name
  for t in "${TARGETS[@]}"; do
    abs="$(abs_target "$t")"
    [ -d "$abs" ] || continue
    preserved="${PRESERVE[$t]:-}"
    for existing in "$abs"/*/; do
      [ -d "$existing" ] || continue
      name="$(basename "$existing")"
      if [ -z "${SKILLS[$name]:-}" ]; then
        if [[ " $preserved " == *" $name "* ]]; then
          log "  (preserve) $t/$name"
          continue
        fi
        CONFLICTS_PATHS+=("${abs}|${name}")
      fi
    done
  done
}

# ---------------------------------------------------------------------------
# Stage 3: decide what to do with conflicts, then execute.
# ---------------------------------------------------------------------------
resolve_conflicts() {
  local decision="cancel"
  if [ "${#CONFLICTS_PATHS[@]}" -gt 0 ]; then
    if [ "$YES" -eq 1 ]; then
      decision="overwrite"
    elif is_tty; then
      echo
      echo "Conflicts detected: skills that exist in a target but not in the shared source:"
      local entry abs name
      for entry in "${CONFLICTS_PATHS[@]}"; do
        abs="${entry%%|*}"
        name="${entry##*|}"
        echo "   - ${abs}  ::  ${name}"
      done
      echo
      PS3="Choose one action for ALL conflicts: "
      select decision in overwrite absorb cancel; do
        if [ -n "$decision" ]; then
          break
        fi
        echo "Invalid choice, try again."
      done
      echo "Decision: $decision"
    else
      echo "No TTY session; NOT deleting conflicts. Run with --yes to overwrite."
      decision="cancel"
    fi
  fi

  case "$decision" in
    overwrite)
      local entry abs name
      for entry in "${CONFLICTS_PATHS[@]}"; do
        abs="${entry%%|*}"
        name="${entry##*|}"
        clean_one "$abs" "$name"
      done
      ;;
    absorb)
      # Copy each conflicting skill into the source (= new authority),
      # then sync it to every target.
      local entry abs name src
      for entry in "${CONFLICTS_PATHS[@]}"; do
        abs="${entry%%|*}"
        name="${entry##*|}"
        src="${abs}/${name}"
        if [ ! -d "$src" ]; then
          continue
        fi
        if [ "$env_kind" = "dry" ]; then
          log "  (absorb) $name -> .agents/skills/$name"
          continue
        fi
        if [ -d "${SOURCE_DIR}/${name}" ]; then
          rm -rf "${SOURCE_DIR}/${name}"
        fi
        mkdir -p "${SOURCE_DIR}/${name}"
        cp -a "$src"/. "${SOURCE_DIR}/${name}/"
        SKILLS["$name"]="${SOURCE_DIR}/${name}"
        log "  (absorb) $name -> .agents/skills/$name"
      done
      # Now distribute every absorbed skill to all targets.
      local t abs skill
      for t in "${TARGETS[@]}"; do
        abs="$(abs_target "$t")"
        [ -d "$abs" ] || continue
        for skill in "${!SKILLS[@]}"; do
          copy_one "${SOURCE_DIR}/${skill}" "${abs}/${skill}"
        done
      done
      ;;
    *)
      log "  (cancel) leaving ${#CONFLICTS_PATHS[@]} conflict(s) untouched"
      ;;
  esac
}

# ---------------------------------------------------------------------------
log "Skill sync from: $SOURCE_DIR"
sync_copy_stage
gather_conflicts
resolve_conflicts
log "Done."