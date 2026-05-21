---
name: lxd-claude-setup
description: "Set up Claude Code on a headless LXD/Linux server (Proxmox or bare). Handles: SSH fingerprint reset, password auth, passwordless key copy, Node.js install, Claude Code install, OAuth login via port forwarding, org/Max subscription auth, and the TUI onboarding loop fix. Use when provisioning a new LXD container for Claude Code agent use."
version: 0.1.0
---

# LXD Claude Code Setup

Runbook for provisioning Claude Code on a headless Proxmox LXD container — including all known failure modes encountered in production.

## Trigger

Use this skill when:
- Setting up Claude Code on a new LXD / headless Linux host
- Claude Code TUI loops on login selection screen
- OAuth fails with `Unknown scope: org:create_api`
- SSH fingerprint mismatch on reprovisioned host
- Need to auth with org Max subscription on a server

---

## Step 1 — SSH Access

**Clear old fingerprint (reprovisioned host):**
```bash
ssh-keygen -R <HOST_IP>
```

**If password auth is disabled** (`Permission denied (publickey)` with `-v`):
On the server console, edit `/etc/ssh/sshd_config`:
```
PasswordAuthentication yes
```
```bash
sudo systemctl restart sshd
```

**Copy SSH key for passwordless access:**
```bash
sshpass -p 'PASSWORD' ssh-copy-id -o StrictHostKeyChecking=no USER@HOST
```
> Install sshpass if needed: `brew install sshpass`

---

## Step 2 — Install Node.js + Claude Code

```bash
# Node.js 22
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -
sudo apt-get install -y nodejs

# Claude Code (requires sudo for global npm)
sudo npm install -g @anthropic-ai/claude-code@2.1.128
```

> Pin to **2.1.128**. Versions >= 2.1.129 request `org:create_api` OAuth scope which fails on Max subscriptions.

Alternatively via official script (then downgrade if needed):
```bash
curl -fsSL https://claude.ai/install.sh | bash
sudo npm install -g @anthropic-ai/claude-code@2.1.128
```

---

## Step 3 — Authenticate (Headless OAuth via Port Forward)

The server has no browser. Forward the OAuth callback port through SSH:

```bash
ssh -L 54545:localhost:54545 USER@HOST
```

Inside that session:
```bash
claude auth login --claudeai
```

A URL will appear — open it in your **local Mac browser**. Complete login. Token saved to `~/.claude/.credentials.json` on the server.

Verify:
```bash
claude auth status        # should show loggedIn: true, subscriptionType: max
claude -p "say hi"        # should respond
```

---

## Step 4 — Fix TUI Onboarding Loop

**Symptom:** `claude` TUI always shows login method selection on every launch, even though `claude auth status` and `claude -p` work fine.

**Root cause:** `~/.claude.json` is missing `hasCompletedOnboarding: true`. The TUI checks this flag before skipping the onboarding flow.

**Fix:**
```bash
python3 -c "
import json
with open('/home/USER/.claude.json', 'r') as f:
    d = json.load(f)
d['hasCompletedOnboarding'] = True
d['lastOnboardingVersion'] = '2.1.128'
with open('/home/USER/.claude.json', 'w') as f:
    json.dump(d, f)
print('Fixed.')
"
```

After this, `claude` launches straight into the TUI. No re-auth needed.

---

## Key Files on the Remote Host

| File | Purpose |
|---|---|
| `~/.claude.json` | TUI state — onboarding flags, account cache, feature flags |
| `~/.claude/.credentials.json` | OAuth tokens (access + refresh) |
| `~/.claude/settings.json` | UI settings (theme, etc.) |

---

## Troubleshooting Reference

| Error | Cause | Fix |
|---|---|---|
| `Permission denied (publickey)` | `PasswordAuthentication no` in sshd | Enable it, restart sshd |
| `Unknown scope: org:create_api` | Claude Code >= 2.1.129 | Downgrade to 2.1.128 |
| TUI loops on login screen | Missing `hasCompletedOnboarding` in `~/.claude.json` | Add flag via python3 snippet above |
| `claude -p` works but TUI doesn't | Credentials saved but onboarding not marked complete | Same fix as above |
| OAuth callback fails on headless | No browser on server | Use `ssh -L 54545:localhost:54545` tunnel |
