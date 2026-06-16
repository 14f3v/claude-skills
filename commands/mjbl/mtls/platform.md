---
description: High-level map + knowledge-base index for the MJBL mTLS device-auth platform (architecture, components, hosts, runbook routing). Wraps the mjbl-mtls-platform skill (MJBL mTLS platform).
argument-hint: "[topic]   e.g. architecture | components | hosts"
---

Use the **mjbl-mtls-platform** skill as the authoritative source for the high-level map, component/host inventory, and runbook index of the MJBL mTLS device-authentication platform. The skill indexes the runbooks under `/home/mjbl/*` (this host is the mTLS remote runner / ops VM — hostname `root-ca`, `192.168.1.25`) — treat those as the source of truth.

Context from $ARGUMENTS: interpret the argument as the topic to focus on —
- `architecture` → walk the four planes (PKI/trust, enrollment, access gateway, operations) and the three end-to-end flows (enroll / access / revoke); point to `mjbl-mtls-production-architecture.md`.
- `components` → the component inventory (signer, CRL/OCSP, relay, gateway, portal BFF/web, device app) with their service names, ports, namespaces, and ArgoCD/GitOps wiring.
- `hosts` → the host/IP/port/namespace map and the 3-cluster topology (rkek8s prod / facility-ArgoCD / `192.168.1.65` UAT), including the `~/.kube/mjbl-prod.config` pin.
- `enrollment` / `revocation` / `portal` / `gateway` / `pki` → summarize that plane and route to the owning runbook + sibling skill.
- a runbook/topic keyword → resolve it to the right `/home/mjbl/mjbl-*.md` via the skill's KB index.
If empty, summarize the platform end-to-end (the map + the four planes + the flows) and offer the KB index so the user can pick a topic.

Read the specific /home/mjbl runbook the skill points to BEFORE executing any prod-touching step, and respect the prod gates: CA-host changes go via `! ssh ca`, k8s-config merges are user-gated, ArgoCD prod writes are user-gated/denied to the agent (reads OK). This command is primarily an orientation/index entry point — for hands-on work in one plane, hand off to the focused sibling skill (`internal-ca`, `mtls`, or the relevant runbook).

VERIFY facts against the actual source docs before stating them — do NOT invent IPs/paths/service names; use the exact figures from `/home/mjbl/mjbl-mtls-production-architecture.md` and the go-live runbook.
