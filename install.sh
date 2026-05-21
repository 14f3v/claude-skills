#!/usr/bin/env bash
# claude-skills installer — symlinks each skills/<name> into ~/.claude/skills/<name>
#
# Usage:
#   ./install.sh              symlink mode (default) — edits in repo propagate live
#   ./install.sh --copy       copy mode — snapshot, edits in repo don't propagate
#   ./install.sh --uninstall  remove symlinks/copies (only those we own)
#   ./install.sh --dry-run    show what would happen, change nothing
#
# Existing files at the target path are backed up to ~/.claude/skills/<name>.bak-<ts>
# so nothing is destroyed silently.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${REPO_DIR}/skills"
DEST_DIR="${HOME}/.claude/skills"
MODE="symlink"
DRY=0

for arg in "$@"; do
  case "$arg" in
    --copy)      MODE="copy" ;;
    --symlink)   MODE="symlink" ;;
    --uninstall) MODE="uninstall" ;;
    --dry-run)   DRY=1 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $arg" >&2
      exit 2
      ;;
  esac
done

run() {
  if [ "$DRY" -eq 1 ]; then
    echo "  [dry-run] $*"
  else
    eval "$@"
  fi
}

mkdir -p "${DEST_DIR}"

TS="$(date +%Y%m%d-%H%M%S)"
PROCESSED=0
SKIPPED=0

for skill_path in "${SRC_DIR}"/*/; do
  [ -d "${skill_path}" ] || continue
  skill_name="$(basename "${skill_path%/}")"
  target="${DEST_DIR}/${skill_name}"

  case "${MODE}" in
    symlink|copy)
      if [ -e "${target}" ] || [ -L "${target}" ]; then
        # If it's already a symlink pointing at the same source, no-op
        if [ -L "${target}" ] && [ "$(readlink -f "${target}")" = "$(readlink -f "${skill_path%/}")" ]; then
          echo "  [=] ${skill_name}: already linked"
          SKIPPED=$((SKIPPED+1))
          continue
        fi
        backup="${target}.bak-${TS}"
        echo "  [!] ${skill_name}: existing path found, backing up to ${backup}"
        run "mv \"${target}\" \"${backup}\""
      fi

      if [ "${MODE}" = "symlink" ]; then
        echo "  [+] ${skill_name}: symlink -> ${skill_path%/}"
        run "ln -s \"${skill_path%/}\" \"${target}\""
      else
        echo "  [+] ${skill_name}: copy -> ${target}"
        run "cp -r \"${skill_path}\" \"${target}\""
      fi
      PROCESSED=$((PROCESSED+1))
      ;;
    uninstall)
      if [ -L "${target}" ] && [ "$(readlink -f "${target}")" = "$(readlink -f "${skill_path%/}")" ]; then
        echo "  [-] ${skill_name}: removing symlink"
        run "rm \"${target}\""
        PROCESSED=$((PROCESSED+1))
      elif [ -d "${target}" ] && diff -rq "${skill_path}" "${target}" >/dev/null 2>&1; then
        echo "  [-] ${skill_name}: removing copy (matches repo)"
        run "rm -rf \"${target}\""
        PROCESSED=$((PROCESSED+1))
      else
        echo "  [=] ${skill_name}: not present or modified locally — leaving alone"
        SKIPPED=$((SKIPPED+1))
      fi
      ;;
  esac
done

echo ""
echo "done — mode=${MODE} processed=${PROCESSED} skipped=${SKIPPED}"
echo "skills now in ${DEST_DIR}:"
ls -la "${DEST_DIR}" 2>/dev/null | grep -E "^[dl]" | awk '{print "  ", $NF, ($1 ~ /^l/ ? "(symlink)" : "")}'
echo ""
echo "Restart Claude Code (close and reopen the CLI) for slash commands to register."
