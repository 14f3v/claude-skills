#!/usr/bin/env bash
# claude-skills installer — symlinks skills/<name> -> ~/.claude/skills/<name>
# AND commands/<entry> -> ~/.claude/commands/<entry>, so the /mjbl:*:* slash
# commands register too (a SKILL shows in the menu as /<skill-name> with dashes;
# a COMMAND under commands/ shows as the colon-namespaced /<path>, e.g.
# commands/mjbl/k8s/dr.md -> /mjbl:k8s:dr).
#
# Usage:
#   ./install.sh                 symlink BOTH skills + commands (default)
#   ./install.sh --skills-only   only skills
#   ./install.sh --commands-only only commands
#   ./install.sh --copy          copy mode (snapshot; repo edits don't propagate)
#   ./install.sh --uninstall     remove symlinks/copies we own (skills + commands)
#   ./install.sh --dry-run       show what would happen, change nothing
#
# Existing targets are backed up to <target>.bak-<ts> so nothing is destroyed silently.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_SRC="${REPO_DIR}/skills"
CMDS_SRC="${REPO_DIR}/commands"
SKILLS_DEST="${HOME}/.claude/skills"
CMDS_DEST="${HOME}/.claude/commands"
MODE="symlink"
DRY=0
DO_SKILLS=1
DO_COMMANDS=1

for arg in "$@"; do
  case "$arg" in
    --copy)          MODE="copy" ;;
    --symlink)       MODE="symlink" ;;
    --uninstall)     MODE="uninstall" ;;
    --dry-run)       DRY=1 ;;
    --skills-only)   DO_COMMANDS=0 ;;
    --commands-only) DO_SKILLS=0 ;;
    -h|--help)       sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

run() { if [ "$DRY" -eq 1 ]; then echo "  [dry-run] $*"; else eval "$@"; fi; }

TS="$(date +%Y%m%d-%H%M%S)"
PROCESSED=0
SKIPPED=0

# link_one <src> <target> <label> — symlink/copy/uninstall a single entry (file or dir)
link_one() {
  local src="$1" target="$2" name="$3"
  case "${MODE}" in
    symlink|copy)
      if [ -e "${target}" ] || [ -L "${target}" ]; then
        if [ -L "${target}" ] && [ "$(readlink -f "${target}")" = "$(readlink -f "${src}")" ]; then
          echo "  [=] ${name}: already linked"; SKIPPED=$((SKIPPED+1)); return
        fi
        echo "  [!] ${name}: existing path, backing up to ${target}.bak-${TS}"
        run "mv \"${target}\" \"${target}.bak-${TS}\""
      fi
      if [ "${MODE}" = "symlink" ]; then
        echo "  [+] ${name}: symlink -> ${src}"; run "ln -s \"${src}\" \"${target}\""
      else
        echo "  [+] ${name}: copy -> ${target}"; run "cp -r \"${src}\" \"${target}\""
      fi
      PROCESSED=$((PROCESSED+1)) ;;
    uninstall)
      if [ -L "${target}" ] && [ "$(readlink -f "${target}")" = "$(readlink -f "${src}")" ]; then
        echo "  [-] ${name}: removing symlink"; run "rm \"${target}\""; PROCESSED=$((PROCESSED+1))
      elif [ -e "${target}" ] && [ ! -L "${target}" ] && diff -rq "${src}" "${target}" >/dev/null 2>&1; then
        echo "  [-] ${name}: removing copy (matches repo)"; run "rm -rf \"${target}\""; PROCESSED=$((PROCESSED+1))
      else
        echo "  [=] ${name}: not present or modified locally — leaving alone"; SKIPPED=$((SKIPPED+1))
      fi ;;
  esac
}

if [ "${DO_SKILLS}" -eq 1 ] && [ -d "${SKILLS_SRC}" ]; then
  echo "== skills -> ${SKILLS_DEST} =="
  mkdir -p "${SKILLS_DEST}"
  for p in "${SKILLS_SRC}"/*/; do
    [ -d "${p}" ] || continue
    link_one "${p%/}" "${SKILLS_DEST}/$(basename "${p%/}")" "skill:$(basename "${p%/}")"
  done
fi

if [ "${DO_COMMANDS}" -eq 1 ] && [ -d "${CMDS_SRC}" ]; then
  echo "== commands -> ${CMDS_DEST} =="
  mkdir -p "${CMDS_DEST}"
  # Link each TOP-LEVEL entry: files (e.g. k8s-setup.md -> /k8s-setup) and the
  # namespace dir mjbl/ (-> /mjbl:<ns>:<cmd>). One mjbl symlink covers mtls + k8s.
  for p in "${CMDS_SRC}"/*; do
    [ -e "${p}" ] || continue
    link_one "${p}" "${CMDS_DEST}/$(basename "${p}")" "cmd:$(basename "${p}")"
  done
fi

echo ""
echo "done — mode=${MODE} processed=${PROCESSED} skipped=${SKIPPED}"
echo "Restart Claude Code (close and reopen the CLI) for the slash COMMANDS to register."
echo "(Skills register live — they appear as /<skill-name>, e.g. /mjbl-k8s-dr.)"
