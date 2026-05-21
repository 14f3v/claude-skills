# claude-skills

Portable Claude Code **user-scope** skills, version-controlled so the same skills are available on every machine you use. Each skill encodes a multi-phase runbook plus the gotchas learned from running it end-to-end on real hosts.

## What's in here

| Skill | What it does |
|---|---|
| [`skills/internal-ca`](skills/internal-ca/SKILL.md) | Bootstrap a 2-tier internal Certificate Authority on a Linux host: Root CA → Intermediate CA → service certs, plus HashiCorp Vault PKI engine, OCSP responder, CRL HTTP server, Ansible deploy playbook, and a 3-mode revocation script. Designed for demo/lab use; surfaces production-hardening pointers without auto-executing them. |
| [`skills/mtls`](skills/mtls/SKILL.md) | Add mutual TLS (server-trusts-client) on top of an existing internal CA + NGINX HTTPS setup. Issues `clientAuth` certs, bundles as PKCS#12 for endpoint install, enforces `ssl_verify_client` with a Root+Intermediate trust bundle, and wires CRL-based revocation. |
| [`skills/lxd-claude-setup`](skills/lxd-claude-setup/SKILL.md) | Provision Claude Code on a headless LXD / Linux server (Proxmox or bare): SSH fingerprint reset, password auth, passwordless key copy, Node.js install, Claude Code install pinned to a working version, OAuth login via SSH port-forward for Max subscriptions, and the TUI onboarding-loop fix. |

`internal-ca` and `mtls` cross-reference each other: `internal-ca` hands off to `mtls` when client cert work comes up; `mtls` assumes `internal-ca` outputs are in place.

### Scope: what this repo does *not* manage

This repo is the source of truth for **user-scope** skills (`~/.claude/skills/<name>`). It intentionally does **not** mirror skills delivered by plugins (under `~/.claude/plugins/`) — e.g. the `superpowers:*`, `astronomer-data:*`, `ui-ux-pro-max:*`, `skill-creator`, `frontend-design`, `claude-api`, and the various Anthropic agent-skills marketplace entries. Those are owned and updated by their plugin marketplaces; copying them in here would diverge and rot. Install/update them through the plugin system, not this repo.

## Install

```bash
git clone <this-repo-url> ~/claude-skills
cd ~/claude-skills
./install.sh
```

That symlinks `skills/internal-ca` and `skills/mtls` into `~/.claude/skills/`. Restart Claude Code to register the slash commands.

### Install modes

| Command | Effect |
|---|---|
| `./install.sh` | **symlink** (default) — edits in this repo immediately reflect in Claude Code |
| `./install.sh --copy` | snapshot copy — repo and live skills diverge after install |
| `./install.sh --dry-run` | preview without changing anything |
| `./install.sh --uninstall` | remove the symlinks/copies (only those we own) |

If a skill with the same name already exists in `~/.claude/skills/`, the installer backs it up to `<name>.bak-<timestamp>` rather than overwriting silently.

## Usage

After install + Claude Code restart, the skills are available two ways:

**1. Auto-trigger** — describe the work, no slash:
```
"set up an internal CA on this VM"           → internal-ca activates
"add mutual TLS to platform.acme.internal"   → mtls activates
```

**2. Explicit slash command:**
```
/internal-ca
/mtls
/mtls iphone.branch.acme.internal     ← with hint
```

## Updating across machines

```bash
cd ~/claude-skills
git pull
# If using symlink install, that's it — live changes are picked up automatically.
# If using --copy install, re-run ./install.sh --copy to refresh.
```

## Editing

Edit the SKILL.md files in this repo (`skills/<name>/SKILL.md`). If you installed via symlink, changes are live immediately — no re-install needed. Commit + push to share with your other machines.

```bash
cd ~/claude-skills
$EDITOR skills/internal-ca/SKILL.md
git add skills/
git commit -m "internal-ca: tighten Phase 5 Vault role"
git push
```

## Layout

```
claude-skills/
├── install.sh                       deploy to ~/.claude/skills/
├── README.md                        you are here
├── .gitignore
└── skills/
    ├── internal-ca/
    │   └── SKILL.md                 2-tier PKI bootstrap
    ├── mtls/
    │   └── SKILL.md                 server-trusts-client mTLS
    └── lxd-claude-setup/
        └── SKILL.md                 Claude Code on headless LXD/Linux
```

## Why these are useful even without Claude

The `SKILL.md` files are readable on their own — phase maps, OpenSSL configs, NGINX directives, known gotchas. If you're standing up an internal CA without Claude in the loop, they double as a battle-tested runbook.
