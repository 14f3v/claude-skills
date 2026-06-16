---
description: Install a private Harbor container registry (with its own self-signed CA + TLS) on an existing Kubernetes cluster. Wraps the harbor-registry skill.
argument-hint: "<harbor-domain>   e.g. mjcr.vte.mjblao.local"
---

Use the **harbor-registry** skill to deploy Harbor on the existing Kubernetes cluster.

Harbor domain / hostname from: $ARGUMENTS — the FQDN clients and nodes use for the registry. It becomes the leaf cert CN, the ingress host, and the `certs.d` path on every node, so it must stay consistent everywhere.

If no domain is given, ask for it before running. Run the pipeline from a local `harbor-infra/` checkout (00 → 01 → 02), then perform the manual CA-trust step on **every** node. Before installing, confirm the persistence and admin-password choices the skill flags (defaults are ephemeral storage and a placeholder password).
