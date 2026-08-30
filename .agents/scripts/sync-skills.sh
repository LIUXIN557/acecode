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
# Usage:
#   .agents/scripts/sync-skills.sh                 # sync all configured targets
#   .agents/scripts/sync-skills.sh --dry-run       # preview without writing
#   .agents/scripts/sync-skills.sh --targets a,b,c # override target list
#   .agents/scripts/sync-skills.sh --force         # also clean stale skills
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
# must never be cleaned out by this script. Key = target dir, value = space
# separated skill names. Any skill listed here is left untouched on that
# target even though it does not come from .agents/skills.
declare -A PRESERVE
PRESERVE[".acecode/skills"]="acecode-release"

DRY_RUN=0
FORCE=0
TARGET_OVERRIDE=""

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    --targets=*) TARGET_OVERRIDE="${arg#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -n "$TARGET_OVERRIDE" ]; then
  IFS=',' read -r -a TARGETS <<< "$TARGET_OVERRIDE"
fi

# ---------------------------------------------------------------------------
if [ ! -d "$SOURCE_DIR" ]; then
  echo "error: source skills dir not found: $SOURCE_DIR" >&2
  exit 1
fi

# Map of skill name -> directory inside SOURCE_DIR.
declare -A SKILLS
for skill_dir in "${SOURCE_DIR}"/*/; do
  [ -d "$skill_dir" ] || continue
  skill="$(basename "$skill_dir")"
  SKILLS["$skill"]="$skill_dir"
done

log() { printf '%s\n' "$*"; }

sync_target() {
  local target="$1"
  local rel_key="$1"   # keep the caller-provided form (relative) to match PRESERVE

  if [[ "$target" == ./* ]] || [[ "$target" != /* ]]; then
    target="${REPO_ROOT}/${target}"
  fi

  if [ ! -d "$target" ]; then
    if [ "$FORCE" -eq 1 ]; then
      log "  creating missing target: $target"
      if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$target"
      fi
    else
      log "  skip (does not exist, use --force to create): $target"
      return
    fi
  fi

  local synced=0 cleaned=0

  # 1) Copy every source skill (and keep stale-skill list for cleaning).
  local skill
  for skill in "${!SKILLS[@]}"; do
    local src="${SKILLS[$skill]}"
    local dst="${target}/${skill}"
    if [ -f "$src/SKILL.md" ] && [ ! -L "$src" ]; then
      mkdir -p "$dst"
      if ! cp -a "$src"/. "$dst"/ > /dev/null 2>&1 || ! diff -qr "$src" "$dst" > /dev/null 2>&1; then
        # Cheap correctness: sync then force-reconcile once.
        if [ "$DRY_RUN" -eq 0 ]; then
          rm -rf "$dst"
          mkdir -p "$dst"
          cp -a "$src"/. "$dst"/
        fi
        log "  (copy) $skill"
      elif [ "$DRY_RUN" -eq 0 ]; then
        # already identical, report as unchanged unless asked
        :
      else
        log "  (copy) $skill (dry-run)"
      fi
      synced=$((synced + 1))
    fi
  done

  # 2) Remove stale skills (present in target but gone from source),
  #    EXCEPT skills preserved per-target (see PRESERVE).
  local preserved="${PRESERVE[$rel_key]:-}"
  local existing
  for existing in "$target"/*/; do
    [ -d "$existing" ] || continue
    local name
    name="$(basename "$existing")"
    if [ -z "${SKILLS[$name]:-}" ]; then
      # Skip if listed as preserve for this target.
      if [[ " $preserved " == *" $name "* ]]; then
        log "  (preserve) $name"
        continue
      fi
      if [ "$DRY_RUN" -eq 0 ]; then
        log "  (clean) $name"
        rm -rf "$existing"
        cleaned=$((cleaned + 1))
      else
        log "  (clean) $name (dry-run)"
        cleaned=$((cleaned + 1))
      fi
    fi
  done

  log "  => $target: synced ${synced} skill(s), cleaned ${cleaned}"
}

# ---------------------------------------------------------------------------
log "Skill sync from: $SOURCE_DIR"
for t in "${TARGETS[@]}"; do
  sync_target "$t"
done
log "Done."