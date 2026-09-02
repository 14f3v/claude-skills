---
name: mjbl-llm-platform
description: This skill should be used when the user asks about the MJBL internal AI assistant or MaaS gateway — "the AI assistant", "Open WebUI", "the LLM platform", "the MaaS gateway", "LiteLLM", "ai.vte.mjblao.local", "maas-admin", the model aliases (**yanmaru / shinkhoun / noy / kanshin / phima / yanmaru-embed**), "the Mac Studio rig", "LM Studio" — AND for its operational faults: "staff can't log in" (AD/LDAP), "the model returns an empty reply" (the reasoning/max_tokens budget trap), "I changed the manifest and nothing happened" (PersistentConfig), "the pod hangs on startup" (the DATA_DIR mount trap), "new users aren't in the pilot group" (stale DEFAULT_GROUP_ID), adding or retiring a model, issuing/scoping an API key for a coding agent, checking token spend, and the RAG/retrieval posture. Covers the facility-cluster topology, the single endpoint serving both chat and an OpenAI-compatible API, the GitOps layout, and every silent-failure trap found while building it.
version: 0.1.0
---

# MJBL Internal LLM Platform (Open WebUI + LiteLLM)

> Staff chat + RAG, and an OpenAI-compatible API for coding agents, from **one hostname on one
> cluster**. Cluster mechanics: `mjbl-k8s-facility`. Manifests: `k8s-config` on GHES.

## Topology — everything is on FACILITY

```
 staff browsers        coding agents         ops
        │                    │                │
        ▼                    ▼                ▼
   ai.vte.mjblao.local/   …/v1        maas-admin.vte.mjblao.local
        └──────────── 10.88.101.190 (facility ingress-nginx) ──────────┘
             │                    │                        │
      ns openwebui          ns litellm               ns litellm
      (Open WebUI)          (gateway)                (admin UI)
             └──── litellm.litellm.svc.cluster.local:4000 ────┘
                              │
                    10.88.18.139:1234  (LM Studio rig)
                    <external provider>   ⚠ LEAVES THE BANK (phima only)
```

**The production cluster holds NOTHING.** It served both halves until 2026-09-02; the
namespaces, the PVC and the whole cross-cluster bridge were deleted. If you find yourself
looking for `openwebui` on `rkek8s`, it is gone and that is correct.

| | |
|---|---|
| chat UI + RAG | `https://ai.vte.mjblao.local/` |
| OpenAI-compatible API | `https://ai.vte.mjblao.local/v1` |
| gateway admin UI | `https://maas-admin.vte.mjblao.local` |
| ⚠ DNS | **Both are still NXDOMAIN** — the pilot runs on hosts-file entries pointing at `10.88.101.190`. Request: `agent-skills/dns-request-localllm-maas.md`. The cert is internal-CA issued and valid regardless of resolution, so a hosts entry is genuinely browser-green. |

Two Ingresses share the host: `openwebui/openwebui` owns `/` **and the TLS certificate**;
`litellm/litellm-api` owns `/v1` and declares **no `tls:`** (secrets are namespaced — exactly
one namespace must own the cert). ingress-nginx orders `Prefix` paths by descending length, so
`/v1` wins over the `/` catch-all.

## Access
```bash
export KUBECONFIG=~/.kube/mjbl-facility.config
# EVERY facility kubectl needs this — the API cert SAN is registry.k8sapi.local
kubectl --tls-server-name=registry.k8sapi.local -n openwebui get pods
kubectl --tls-server-name=registry.k8sapi.local -n litellm  get pods
```
Placement is deliberate and inverted between the two:

| workload | node | why |
|---|---|---|
| `litellm` | `mjbl-cicd` / `mjbl-registry` | **requires** `mjbl-network/egress=allowed` — it must reach `phima` and, later, tool calls |
| `openwebui` | `k8s-fc-033` | **prefers** `mjbl-network/egress=denied` — needs no internet, and that node is the idle one. Preferred not required, so losing it cannot strand every staff chat. Legal only because the PVC is **RWO**: `k8s-fc-033` lacks `nfs-common` and Longhorn RWX fails there. |

## The models — six aliases, one rig (except `phima`)

All are `google/gemma-4-12b` on the rig unless stated. Aliased **by intent, not by weights**.

| alias | reasoning | rpm | timeout | purpose |
|---|---|---|---|---|
| `yanmaru` | on | 120 | 900 | **general purpose / default** |
| `shinkhoun` | on | 60 | 1800 | long / deep work |
| `noy` | **off** | 240 | 300 | fast, short answers |
| `kanshin` | **off** | 120 | 900 | coding agents |
| `phima` | off | 60 | 900 | ⚠ **EXTERNAL** — `gemma-4-12b-qat` on a privately-operated rig reached over the public internet. Endpoint is in the gateway ConfigMap and the `litellm-env` Secret, not here. |
| `yanmaru-embed` | — | 600 | 900 | `text-embedding-bge-m3`, retrieval only |

Only `yanmaru` and `phima` appear in the chat picker (`OPENAI_API_CONFIGS` in the Open WebUI
ConfigMap). When `model_ids` is non-empty Open WebUI **skips** the upstream `/v1/models` call
entirely — so new models are not auto-discovered, add them there deliberately. This is what
keeps `yanmaru-embed` out of the UI, where it would appear selectable and fail confusingly.

## The rig — LM Studio on the Mac Studio
`10.88.18.139:1234`, headless. If **every** model 000s or the gateway reports no models:
```bash
ssh mjbl-mac-studio 'lms daemon up && lms server start --bind 0.0.0.0 && lms ps'
```
⚠ **It sleeps mid-inference and it does not look like sleep.** Trivial requests return 200 in
~0.05s while real GPU inference dies at ~130s, because DarkWake serves the HTTP layer with the
GPU parked. `sudo pmset -a sleep 0 disablesleep 1` is the fix. A "the network is flaky"
report against this rig is almost always this.

## Retrieval (RAG)
Embeddings are served by the rig **through the gateway**, so no local SentenceTransformers
model is ever loaded and no HuggingFace download is attempted.

- `RAG_EMBEDDING_ENGINE=openai`, `RAG_EMBEDDING_MODEL=yanmaru-embed` → **bge-m3**.
- bge-m3 was chosen on **measurement, not preference**: separation margin on Lao content was
  **+0.2913** vs **+0.0156** for nomic-embed-text. Nomic is effectively blind to Lao.
- `ENABLE_RAG_HYBRID_SEARCH=False` — **Lao has no spaces between words**, so BM25/keyword
  scoring is near-useless and the reranker it enables wants a download this cluster cannot do.
  Dense-only is correct here, not a limitation to fix.
- `CHUNK_OVERLAP=200` (up from 100) for the same reason: a character splitter lands mid-word
  far more often without word boundaries.
- `RAG_TEXT_SPLITTER=""` — do **not** set `"token"`: tiktoken fetches BPE files from the
  internet on first use and would hang, not error.

**Status: the retrieval eval is BLOCKED** on corpus, not on tech — scanned PDFs extract to zero
characters and there is no OCR. Go/no-go is ≥70% top-5, reported separately for Lao and English.

## Active Directory
Enabled and working, using the **same directory settings GHES and Rancher have used for
months** — read them from those systems rather than reproducing them here. The search base,
domain structure, bind account and server address are **not published in this repository**:
they live in the `openwebui-env` Secret and in the private
`agent-skills/ad-request-localllm.md`.

- Username attribute is `sAMAccountName`.
- ⚠ **`LDAP_USE_TLS` defaults to `True`.** The transport this deployment actually uses, and why,
  is recorded in the private AD request doc. Mismatching it produces a handshake failure that
  looks exactly like a firewall problem — check the doc before assuming the network.
- **Open WebUI keys accounts on `mail`.** A user whose directory object has an empty `mail`
  **cannot log in, and it presents as a wrong password.** Coverage is good but not complete;
  the measured figures and the affected accounts are in the private doc.
- `DEFAULT_USER_ROLE=pending` — an admin activates every account by hand. There is no
  `LDAP_SEARCH_FILTER` yet (the AD group does not exist), so any directory user can
  *authenticate* but none can *use* anything until activated.
- Host/port and the bind DN/password come from the `openwebui-env` Secret, deliberately **not**
  from git. They are commented out of the ConfigMap rather than given placeholders — `envFrom`
  applies the Secret after the ConfigMap, so a placeholder would silently become live if the
  Secret key were missing, and the failure would point at the wrong thing.

Verify reachability from a pod before blaming credentials — this is the single most useful
first check, and it needs no secrets:
```bash
kubectl --tls-server-name=registry.k8sapi.local -n litellm exec deploy/litellm -- python3 -c "
import socket, os
host = os.environ.get('DC_HOST')          # supply at run time; not stored here
for p in (389, 636):
    s = socket.socket(); s.settimeout(5)
    print(p, 'OPEN' if s.connect_ex((host, p)) == 0 else 'BLOCKED')"
```

## API keys and spend
Virtual keys are issued by the gateway and can be **scoped to specific models** — the Claude
Code key allows only `kanshin`, and asking for anything else returns
`key_model_access_denied`. Keys, budgets and spend live in the **external microloan Postgres**,
not in the pod, which is why the cluster migration needed no data migration for the gateway.

```bash
KEY=<master>
curl -s -H "Authorization: Bearer $KEY" https://maas-admin.vte.mjblao.local/spend/logs | jq '.[0:5]'
```
⚠ Without Redis, rate limits and budgets are held **per worker**. `LITELLM_DISABLE_NO_REDIS_WARNING`
suppresses the banner and is safe **only** while one replica × one worker holds. If you scale
`replicas`, deploy Redis in the same change or a key with `rpm 30` silently gets `30 × N`.

## GitOps
```
k8s-config/deployments/
├── openwebui/facility/   + argocd/application-facility.yaml
└── litellm/facility/     + argocd/application-facility.yaml
```
Both Applications live in the **facility** `argocd` namespace with
`destination.server: https://kubernetes.default.svc` (in-cluster), `prune: true`,
`selfHeal: true`. Out-of-band and **never** managed by ArgoCD: Secrets `openwebui-env` /
`litellm-env`, ConfigMap `openwebui-trust`.

⚠ **`selfHeal` will fight any manual change**, including `kubectl scale`. To quiesce for
maintenance, suspend automated sync first and restore it from a trap:
```bash
A='{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true,"allowEmpty":false}}}}'
kubectl … -n argocd patch application openwebui-facility --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
# … work …
kubectl … -n argocd patch application openwebui-facility --type=merge -p "$A"
```

## Governance posture
Restrictive by default until Compliance/Risk sign off
(`agent-skills/data-classification-request-localllm.md`): signup off, admin chat access off,
admin export off, community sharing off, web search off, user file upload off, knowledge
workspace off. **Relax each individually, as its own reviewed commit — never in bulk.**

---

# ⚠ Traps — every one of these returns success

The reason this skill exists. None would be found by checking a status code.

**`reasoning_effort` must travel in `extra_body`.** LiteLLM does not recognise gemma as
reasoning-capable, so with `drop_params: true` a bare `reasoning_effort` is discarded
**silently** — the request succeeds and the model reasons anyway. Prove the parameter arrived
by inspecting LM Studio's **rendered prompt template**, not the response.

**`max_tokens` is a combined budget.** Reasoning tokens are spent before any content is
emitted. Too small a budget yields empty `content` with a populated `reasoning_content` and a
non-zero `usage` — which reads as "the model returned nothing".

**`ENABLE_PERSISTENT_CONFIG=False` is mandatory.** Most Open WebUI settings are *PersistentConfig*:
written to the database on first boot, after which the env var is **ignored**. Under `selfHeal`
this is the classic "I changed the manifest and nothing happened". The cost — admin-UI changes
do not survive a restart — is the right trade, because it makes every setting a reviewable commit.

**Mount the data volume at `/data`, never `/app/backend/data`.** The image pre-bakes its models
under `/app/backend/data/cache` (~265 MB). Mounting an empty volume there masks all of them, and
with `OFFLINE_MODE=True` they cannot be refetched — the pod **hangs** rather than erroring.
Check with `du -sh /app/backend/data/cache`.

**`OFFLINE_MODE=True` is load-bearing here, unlike on prod.** Production had no route out, so the
flag was belt-and-braces. On facility two of three nodes have egress and placement is only a
*preference* — this flag is now the only thing keeping the workload off the internet.

**`DEFAULT_GROUP_ID` is database-specific.** It names the `MJBL-AI-Pilot` group by id. Rebuild
the namespace and the group is recreated with a **new** id; auto-assignment then stops with no
error at all, because `apply_default_group_assignment()` logs and swallows the failure. Re-read
it from the `group` table after any rebuild.

**`phima` leaves the bank network.** Selecting it sends the prompt *and, in a retrieval session,
the internal document text retrieved to answer it* to a privately-operated rig over the public
internet. Embeddings stay internal (`yanmaru-embed`), so the **index** never leaves. It is an
interim measure justified by measurement — 26.6s vs 66.7s prefill on an ~8.4k-token prompt —
and should be the **first** thing retired when real hardware arrives. Set a description on it in
Admin Panel → Workspace → Models so staff know where it runs.

**Single replica only.** Chroma is a local SQLite PersistentClient and is not fork-safe;
multiple replicas over one data dir corrupt it. `UVICORN_WORKERS=1` is the same constraint
inside the pod, and `strategy: Recreate` is required because a RollingUpdate can never complete
against an RWO volume the old pod still holds.

**Coding agents are a poor fit for this rig.** A Claude Code session against `kanshin` burned
**202,493 tokens for zero completions**, while the same model made the same edit directly in
111 tokens / 2s. Prefill dominates agentic loops. This is a hardware conclusion, not a bug —
see the RTX PRO 6000 sizing in `agent-skills/infra-proposal-localllm-pilot.md`.

## Data durability — check this before promising anything
The pilot's data (chats, users, the pilot group, the vector store) lives on a single Longhorn
claim in the facility cluster. **Confirm the current replication and backup posture before
telling anyone it is safe** — do not assume it from this document:

```bash
V=$(kubectl --tls-server-name=registry.k8sapi.local -n openwebui get pvc openwebui-data -o jsonpath='{.spec.volumeName}')
kubectl --tls-server-name=registry.k8sapi.local -n longhorn-system get volumes.longhorn.io "$V" \
  -o jsonpath='replicas={.spec.numberOfReplicas} robustness={.status.robustness}{"\n"}'
kubectl --tls-server-name=registry.k8sapi.local -n longhorn-system get backuptargets.longhorn.io
```

In-cluster replication survives a node loss; it does **not** survive a cluster loss, an
accidental namespace delete, or operator error. If no backup target is configured, that is a
decision to make **before** the pilot widens, not after — MinIO is already in-cluster. Current
status and the rationale are tracked in the private `agent-skills/localllm-maas-rollout.md`.

## Related
`mjbl-k8s-facility` (cluster + ArgoCD) · `mjbl-k8s-platform` (estate orientation) ·
`harbor-registry` and `registry-image-warming` (the Open WebUI image cannot come through
Harbor's proxy-cache — its largest layer is 1246.7 MB and the cache deadlocks above ~713 MB;
it lives in `library/` and is digest-pinned) ·
`agent-skills/localllm-maas-rollout.md` (the full build/migration record).
