# P2P Intelligence — Approximate Sizing (this demo)

> Scope: sizing for **this exact demo** on `fevm-lakemeter-demo` (AWS, serverless).
> Data volume is tiny (308 invoices / 188 exceptions / 15 rich threads), so cost is
> driven by **serverless SQL warehouse minutes**, **pay-per-token model calls**, and
> **always-on serving/app endpoints** — not by data size or storage.
> Rates are list, USD, AWS, and approximate — confirm against the current price list.

## What actually runs

| Component | Type | Sizing | Notes |
|---|---|---|---|
| SQL Warehouse | Serverless SQL, **Small** | on-demand, auto-stop 10 min | runs all 7 pipeline SQL steps + powers the App's queries |
| Foundation Model API (Claude Sonnet) | Pay-per-token | ~200 model calls per full pipeline run | `ai_query` classify (188 rows) + contract extract |
| Agent Bricks Supervisor | Model Serving endpoint | scale-to-zero capable | contract validation + Ask chat |
| Knowledge Assistant + Vector Search | Managed (small index, 15 docs) | smallest tier | contract-clause retrieval |
| Genie space | Serverless SQL (shares warehouse) | per-query | ad-hoc Q&A |
| Databricks App | 1 App (0.5 vCPU / 2 GB) | always-on while enabled | FastAPI + React |
| Storage (Delta + Volume) | S3-backed | < 1 GB | negligible |

## Compute estimate — per full pipeline run

The 7-task Lakeflow job end-to-end is dominated by the AI classify step (188 sequential
`ai_query` calls). Observed wall-clock ≈ **6–10 minutes**, most of it in `ai_classify`.

| Item | Qty / run | Basis | Est. cost / run |
|---|---|---|---|
| Serverless SQL — Small (~$0.70/DBU-hr equiv, Small ≈ ~4 DBU/hr) | ~10 warehouse-min | match/dedup/views/gen are seconds; classify holds the warehouse while calling FMAPI | **~$0.50–0.90** |
| FMAPI tokens — classify | ~188 calls × ~1.5k in + ~0.2k out | Claude Sonnet ≈ $3/1M in, $15/1M out | **~$1.00–1.50** |
| FMAPI tokens — contract validate | ~2 vendor calls + extractor | small | **~$0.05** |
| **Total per full run** | | | **≈ $1.5–2.5** |

One-time: the 15 showcase email threads were LLM-authored once (~$0.30, not repeated).

## Always-on / standing cost (per month, if left running)

| Component | Assumption | Est. / month |
|---|---|---|
| Databricks App (0.5 vCPU / 2 GB, 24×7) | ~$0.10–0.15/hr equiv | **~$75–110** |
| Supervisor + KA serving endpoints | scale-to-zero when idle; small when warm | **~$0 idle → ~$50–150 if kept warm** |
| Vector Search index (15 docs, smallest) | standing index | **~$0 on serverless tier / minimal** |
| SQL Warehouse | auto-stops at 10 min idle | **$0 when idle** |
| Storage (< 1 GB S3) | | **< $1** |

**Practical demo posture:** stop the App and let endpoints scale to zero between demos →
near-zero standing cost. A full pipeline refresh + a demo session ≈ **$3–6** of consumption.

## If this went to production (order-of-magnitude, NOT this demo)

Rough scaling from the same architecture to a real AP volume. Illustrative only.

| Driver | Demo | ~50k invoices/mo prod | Prod cost driver |
|---|---|---|---|
| Exceptions to classify | ~190 | ~10–15k/mo (assume ~25% exception rate) | FMAPI tokens ≈ **$150–400/mo** |
| Contract checks | ~10 | ~1–2k/mo | Supervisor calls + Vector Search |
| SQL Warehouse | Small on-demand | Small–Medium, scheduled batches | **~$300–800/mo** |
| Model Serving | scale-to-zero | provisioned throughput if latency-critical | **$0–2k/mo** depending on SLA |
| App + Genie | 1 App | 1–2 Apps + Genie | **~$150–300/mo** |
| Vector Search | 15 docs | 1–10k contracts | small index, **~$50–200/mo** |

**Prod order-of-magnitude: ~$1–4k/month** for the platform at ~50k invoices/mo — set
against the labour it removes (this demo clears ~65% touchless) and the overpayments it
blocks before the payment run. The ROI case is the avoided cost, not the platform cost.

## Sizing notes / assumptions
- Serverless SQL billed per-second while active; the classify step keeps the warehouse
  alive during FMAPI round-trips — batching `ai_query` (it already vectorises across rows)
  keeps this short. Larger volumes benefit from a Medium warehouse to parallelise.
- FMAPI is pay-per-token with **no idle cost** — the cheapest way to run the AI at low volume.
- Agent Bricks / Model Serving endpoints scale to zero; keep-warm only if demo latency matters.
- All figures list price, AWS, USD, approximate. GCP/Azure and negotiated rates differ.
