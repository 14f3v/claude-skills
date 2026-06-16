---
description: Provision, join, or reset a bare-metal Kubernetes + Rancher cluster (single-node, HA, or node join). Wraps the k8s-bare-metal skill.
argument-hint: "[single-node|ha|join|worker|reset] --hostname <h> [--iprange <r> --ingressip <ip>] [--endpoint <lb:6443>] [-y]"
---

Use the **k8s-bare-metal** skill to provision, extend, or reset a bare-metal Kubernetes cluster.

Interpret the request from: $ARGUMENTS

- The first token, if present, is the mode: `single-node` (default), `ha`, `join`/`worker`, or `reset`.
- Remaining tokens are script flags: `--hostname`, `--iprange`, `--ingressip`, `--ha`, `--endpoint`, `--apiserver-cert-extra-sans`, `--join`, `--token`, `--discovery-token-ca-cert-hash`, `--control-plane`, `--certificate-key`, `-y`.

Follow the skill's "When to act vs ask first" gate: if required params for the chosen mode are missing or ambiguous, ask one batched question before running. Pass `-y` for non-interactive runs (the script's prompts have no TTY guard). For `reset`, use `k8s-node-cleanup.sh` per the skill's Cleanup section — and never `-y` if Longhorn data matters.
