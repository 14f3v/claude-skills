---
description: Install the CI/CD layer — Argo CD (GitOps) and/or a self-hosted GitHub Actions runner that trusts the Harbor registry CA. Wraps the cicd-platform skill.
argument-hint: "[argocd|runner|all] [--org <github-org>]"
---

Use the **cicd-platform** skill to install Argo CD and/or the self-hosted GitHub Actions runner on the cluster.

Scope from: $ARGUMENTS — `all` (default), `argocd` only, or `runner` only. `--org` overrides the GitHub org the runner registers to.

Before installing the runner, confirm the skill's two unscripted prerequisites: the `harbor-ca` secret in `actions-runner-system`, and ARC's GitHub org auth (App or PAT) — without these the runner pod is stuck and can't register. Run from a local `cicd-infra/` checkout and follow the skill's phase map and verify gates.
