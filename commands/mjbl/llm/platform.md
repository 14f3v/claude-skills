---
description: Operate the MJBL internal AI assistant + MaaS gateway — the single endpoint, the six model aliases, AD login, API keys, RAG posture, and the silent-failure traps. Wraps the mjbl-llm-platform skill.
argument-hint: "[topic]   e.g. access | models | rag | ad | keys | deploy | troubleshoot | <intent>"
---

Use the **mjbl-llm-platform** skill. Both halves run on the **facility** cluster behind one
hostname: `https://ai.vte.mjblao.local/` is Open WebUI, `/v1` is the LiteLLM gateway,
`maas-admin.vte.mjblao.local` is the gateway admin UI. **The production cluster holds nothing** —
it was fully retired on 2026-09-02. Every facility `kubectl` needs
`--tls-server-name=registry.k8sapi.local`.

Interpret $ARGUMENTS:

- `access` → `KUBECONFIG=~/.kube/mjbl-facility.config`, namespaces `openwebui` and `litellm`.
  Both hostnames are still **NXDOMAIN**; the pilot uses hosts entries → `10.88.101.190`.
- `models` → the six aliases (`yanmaru` default, `shinkhoun` long, `noy` fast, `kanshin`
  coding, `phima` ⚠ **external**, `yanmaru-embed` retrieval-only). All on the rig at
  `10.88.18.139:1234` except `phima`. Adding one means editing the gateway ConfigMap **and**
  `OPENAI_API_CONFIGS` in the Open WebUI ConfigMap — a non-empty `model_ids` makes Open WebUI
  skip `/v1/models` entirely, so nothing is auto-discovered.
- `rag` → bge-m3 via `yanmaru-embed`, chosen on measured Lao margin (+0.2913 vs +0.0156);
  hybrid search off because Lao has no inter-word spaces. The eval is BLOCKED on corpus, not tech.
- `ad` → `sAMAccountName`; the search base, transport and bind account are NOT in this repo —
  see the `openwebui-env` Secret and the private `agent-skills/ad-request-localllm.md`.
  Accounts key on `mail`: an empty `mail` presents as a *wrong password*. Test reachability
  from a pod before suspecting credentials.
- `keys` → virtual keys, model-scoped (the Claude Code key allows only `kanshin`). Keys and
  spend live in the external Postgres. Rate limits are per-worker without Redis.
- `deploy` → `k8s-config/deployments/{openwebui,litellm}/facility/`, two `-facility` ArgoCD
  Applications, in-cluster destination, `selfHeal: true`. Suspend automated sync before any
  manual scale, and restore it from a trap.
- `troubleshoot` → work the traps first, because **they all return success**: empty reply →
  `max_tokens` is a combined budget with reasoning; reasoning ignored → `reasoning_effort` must
  be in `extra_body` (`drop_params` eats a bare one); manifest change no-op →
  `ENABLE_PERSISTENT_CONFIG`; pod hangs at startup → the data volume masked the baked model
  cache; new users not in the pilot group → stale `DEFAULT_GROUP_ID`; every model dead → the
  Mac Studio slept (`lms daemon up`), which looks like a network fault because trivial requests
  still 200.
- an operational intent → read freely; treat model/config changes as GitOps commits, not
  `kubectl edit`, since `selfHeal` reverts them.

⚠ Two standing cautions: selecting **`phima`** sends the prompt *and any retrieved internal
document text* outside the bank (embeddings stay internal, so the index does not) — retire it
first when real hardware lands. And **verify the volume's replication and backup
posture** before calling the pilot's data safe — in-cluster replicas survive a node loss, not a
cluster loss.
