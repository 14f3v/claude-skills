# claude-skills

Portable Claude Code **user-scope** skills, version-controlled so the same skills are available on every machine you use. Each skill encodes a multi-phase runbook plus the gotchas learned from running it end-to-end on real hosts.

## What's in here

| Skill | What it does |
|---|---|
| [`skills/internal-ca`](skills/internal-ca/SKILL.md) | Bootstrap a 2-tier internal Certificate Authority on a Linux host: Root CA → Intermediate CA → service certs, plus HashiCorp Vault PKI engine, OCSP responder, CRL HTTP server, Ansible deploy playbook, and a 3-mode revocation script. Designed for demo/lab use; surfaces production-hardening pointers without auto-executing them. |
| [`skills/mtls`](skills/mtls/SKILL.md) | Add mutual TLS (server-trusts-client) on top of an existing internal CA + NGINX HTTPS setup. Issues `clientAuth` certs, bundles as PKCS#12 for endpoint install, enforces `ssl_verify_client` with a Root+Intermediate trust bundle, and wires CRL-based revocation. |
| [`skills/lxd-claude-setup`](skills/lxd-claude-setup/SKILL.md) | Provision Claude Code on a headless LXD / Linux server (Proxmox or bare): SSH fingerprint reset, password auth, passwordless key copy, Node.js install, Claude Code install pinned to a working version, OAuth login via SSH port-forward for Max subscriptions, and the TUI onboarding-loop fix. |

`internal-ca` and `mtls` cross-reference each other: `internal-ca` hands off to `mtls` when client cert work comes up; `mtls` assumes `internal-ca` outputs are in place.

## MJBL mTLS platform suite (`/mjbl:mtls:*`)

Operational skills for the **live MJBL mTLS ecosystem deployed on this host** — distinct from the generic `internal-ca` / `mtls` how-to skills above. Each one **indexes the authoritative runbooks under `/home/mjbl/*` as source-of-truth** (this host is the mTLS *remote runner*) and distills the live facts (hosts, IPs, services, paths, gotchas). Invoke via the `/mjbl:mtls:<command>` wrappers, or let Claude auto-activate the skill from its frontmatter triggers.

| Skill | Command | What it covers |
|---|---|---|
| [`mjbl-mtls-platform`](skills/mjbl-mtls-platform/SKILL.md) | `/mjbl:mtls:platform` | Ecosystem map + KB index (entry point): CA host, relay, gateway, device app, portal; 3-cluster topology; an index of every `/home/mjbl/mjbl-*.md` runbook. |
| [`mjbl-ca-operations`](skills/mjbl-ca-operations/SKILL.md) | `/mjbl:mtls:ca` | Prod CA host `10.88.1.116`: Vault 2-tier PKI, OCSP/CRL (`refresh-crl.sh`), CA-host rotation, prod hardening. |
| [`mjbl-enrollment-plane`](skills/mjbl-enrollment-plane/SKILL.md) | `/mjbl:mtls:enroll` | Signer (`mjbl-enroll-signer` :8444) + relay (LB `10.88.101.143:8443`): mint/sign/revoke/allowlist, logs, relay-cert rotation. |
| [`mjbl-client-provisioning`](skills/mjbl-client-provisioning/SKILL.md) | `/mjbl:mtls:client` | agency_v2 device app: build-time dart-defines, Model-A enrollment, signed APK + Firebase distribution, claim-QR. |
| [`mjbl-cert-lifecycle`](skills/mjbl-cert-lifecycle/SKILL.md) | `/mjbl:mtls:cert` | Cert rotation (relay/CA) + the **3-hop** device revocation chain + the revocation post-mortem. |
| [`mjbl-operator-portal`](skills/mjbl-operator-portal/SKILL.md) | `/mjbl:mtls:portal` | Operator portal BFF / RBAC / LDAP-HTTP-delegate + signer admin endpoints + P5 cutover. |
| [`mjbl-mtls-troubleshooting`](skills/mjbl-mtls-troubleshooting/SKILL.md) | `/mjbl:mtls:troubleshoot` | Symptom→cause→fix decision tree for enrollment/mTLS failures (e.g. "could not reach", revoked-device-still-works). |

> The `/mjbl:mtls:*` slash commands live in `commands/mjbl/mtls/` and load via the plugin system. After pulling, run `/plugin install claude-skills@claude-skills` (or reload the plugin) and restart Claude Code so they register. The skills themselves also install via `./install.sh` (symlink mode auto-discovers every `skills/<name>/`).

### Scope: what this repo does *not* manage

This repo is the source of truth for **user-scope** skills (`~/.claude/skills/<name>`). It intentionally does **not** mirror skills delivered by plugins (under `~/.claude/plugins/`) — e.g. the `superpowers:*`, `astronomer-data:*`, `ui-ux-pro-max:*`, `skill-creator`, `frontend-design`, `claude-api`, and the various Anthropic agent-skills marketplace entries. Those are owned and updated by their plugin marketplaces; copying them in here would diverge and rot. Install/update them through the plugin system, not this repo.

## Install (new machine bootstrap)

This repo can be consumed two ways. Pick whichever fits the machine.

### Option A — As a Claude Code plugin (recommended)

The repo ships a `.claude-plugin/` manifest, so it can be registered as a marketplace and installed through Claude Code's plugin system. Inside Claude Code:

```
/plugin marketplace add 14f3v/claude-skills
/plugin install claude-skills@claude-skills
```

That installs all bundled skills (`internal-ca`, `mtls`, `lxd-claude-setup`) under `~/.claude/plugins/`, with updates managed by `/plugin` (no `git pull` needed). Confirm with `/plugin` — `claude-skills` should appear in the installed list.

### Option B — As a user-scope skill collection (clone + symlink)

For machines where you prefer the user-scope skill layout (`~/.claude/skills/<name>`), or where you want to edit skills in-place and have the changes reflect live:

```bash
git clone https://github.com/14f3v/claude-skills.git ~/claude-skills
cd ~/claude-skills
./install.sh
```

`install.sh` symlinks **every** `skills/<name>/` directory in this repo into `~/.claude/skills/<name>`. That means: clone once, then any future `git pull` is picked up live — no re-install needed. Restart Claude Code after the first install so the slash commands register.

> The two options are mutually exclusive on a given machine — pick one. Mixing them would register the same skills twice under different paths.

### Verify the install

After restarting Claude Code, confirm the skills are linked and visible:

```bash
ls -l ~/.claude/skills/                      # entries should be symlinks into ~/claude-skills/skills/
```

Inside Claude Code, the skills should appear in the available-skills list under their bare names (`internal-ca`, `mtls`, `lxd-claude-setup`, …) and respond to their slash commands.

### Install modes

| Command | Effect |
|---|---|
| `./install.sh` | **symlink** (default) — edits in this repo immediately reflect in Claude Code |
| `./install.sh --copy` | snapshot copy — repo and live skills diverge after install |
| `./install.sh --dry-run` | preview without changing anything |
| `./install.sh --uninstall` | remove the symlinks/copies (only those we own) |

If a real (non-symlink) skill with the same name already exists in `~/.claude/skills/`, the installer backs it up to `<name>.bak-<timestamp>` rather than overwriting silently. Re-running `./install.sh` on a machine that's already linked is a safe no-op for already-linked entries.

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

## Editing an existing skill

Edit the SKILL.md files in this repo (`skills/<name>/SKILL.md`). If you installed via symlink, changes are live immediately — no re-install needed. Commit + push to share with your other machines.

```bash
cd ~/claude-skills
$EDITOR skills/internal-ca/SKILL.md
git add skills/
git commit -m "internal-ca: tighten Phase 5 Vault role"
git push
```

## Adding a new skill

To bring a new skill under this repo's management:

```bash
cd ~/claude-skills
mkdir -p skills/<new-name>
$EDITOR skills/<new-name>/SKILL.md             # frontmatter: name, description, version
$EDITOR .claude-plugin/plugin.json             # append "./skills/<new-name>" to the "skills" array
./install.sh                                   # (Option B machines) symlink the new skill into ~/.claude/skills/
git add skills/<new-name>/ .claude-plugin/plugin.json README.md
git commit -m "Add <new-name> skill"
git push
```

After pushing, machines installed via Option A pick up the new skill on the next `/plugin update`; machines installed via Option B pick it up on `git pull` (no re-install needed since the symlink already points at the repo root).

SKILL.md frontmatter convention used by skills in this repo:

```yaml
---
name: <new-name>
description: "<one-paragraph description Claude Code uses to decide when to trigger the skill>"
version: 0.1.0
---
```

Also add a row to the **What's in here** table above so the new skill is discoverable on GitHub.

**Migrating an existing user-scope skill** (already living at `~/.claude/skills/<name>` outside this repo): move/copy its contents into `skills/<name>/` here, then run `./install.sh`. The installer detects the standalone directory at the target, backs it up to `<name>.bak-<timestamp>`, and replaces it with the symlink. Delete the backup once you've confirmed the migration is correct.

## Layout

```
claude-skills/
├── .claude-plugin/                  plugin marketplace manifests (Option A install)
│   ├── marketplace.json             declares the marketplace + plugin
│   └── plugin.json                  plugin metadata + skill paths
├── install.sh                       deploy to ~/.claude/skills/ (Option B install)
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
