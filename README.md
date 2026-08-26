# Three-Way Match Agent

**An agent-native accounts-payable exception resolver.** It reads the *unstructured* record that rides with a failed invoice — the full email thread, the PO comment, the invoice memo — classifies each exception into an action lane with an LLM, and autonomously validates contractual price claims against the **actual vendor contracts** before any payment is approved. Built on Databricks (AI Functions + Agent Bricks + Unity Catalog) with a Databricks App front end.

---

## Why it matters

In a typical AP shop, invoices that fail a 3-way match (invoice vs. purchase order vs. goods receipt) fall out to a **manual exceptions queue**. A clerk opens each one, hunts through email for an approval, checks whether a price increase is allowed under the vendor's contract, and decides. It's slow, inconsistent, and it leaks money two ways:

- **False positives** — legitimate, already-approved variances (an air-freight premium a plant director signed off on; extra consulting days approved in an SOW) sit in the queue for days, delaying payments and burning clerk time.
- **False negatives** — a supplier bills a 9% annual increase, the tolerance band lets it through, but their contract caps increases at **5%**. The overpayment is invisible to rules-based checks.

Deterministic rules can't fix this, because **the deciding information is in language, not numbers**: two invoices with an identical +18% price delta belong in *different* lanes purely because of what the email thread says. This demo shows an agent doing that reading — and doing the contract lookup a human would otherwise do by hand.

**The impact:**
- **Touchless approval** of exceptions that carry genuine written authorization — cleared and audit-logged automatically instead of waiting in a queue.
- **Overpayments caught** that tolerance bands miss — contract breaches flagged by reading the real cap clause, not the supplier's claim.
- **Every decision audited** — each auto-approval records the extracted business reason and the cited contract clause, so the automation is defensible to audit.
- **Clerks focus on the genuine unknowns** — only true violations and un-evidenced claims route to a human.

This is the email-agent-with-contracts pattern for finance operations (P2P / accounts payable), and it maps directly to the kind of **Invoice Processing** and **P2P Agent Automation** use cases finance teams are prioritizing.

---

## How it works

A 7-step pipeline runs the data through match → classify → validate → gate → approve, and a Databricks App lets an AP user work the resulting queue and ask questions.

```
PO ─┐
GRN ─┼─► 3-way match ─► exceptions ─► AI Classify (email-aware) ─┬─► TOUCHLESS_AUTO_APPROVE
INV ─┘   (deterministic   (failed        │ Claude reads the       │
          deltas)          invoices)      │ whole thread           ├─► EMAIL_EVIDENCE_APPROVE
                                          │                        │
                                          ▼                        ├─► CONTRACT_CHECK_NEEDED ─► Agent Bricks
                                    duplicate gate                 │      Supervisor + Knowledge Assistant
                                    (pre-payment hold)             │      reads the vendor contract clause:
                                          │                        │      WITHIN_CONTRACT ✓ / BREACH ✗
                                          ▼                        │
                                 maker-checker approvals ◄─────────┴─► CLERK_REVIEW
                                    + append-only audit
```

### The four dispositions
The classifier assigns each exception to exactly one lane — **the LLM decides from the language, not a `CASE` statement**:

| Disposition | Meaning | Outcome |
|---|---|---|
| `TOUCHLESS_AUTO_APPROVE` | Within tolerance / no ambiguity | Auto-approved |
| `EMAIL_EVIDENCE_APPROVE` | The thread contains genuine written authorization (named approver, SOW change, documented pre-approval) | Auto-approved + reason recorded for audit |
| `CONTRACT_CHECK_NEEDED` | The increase claims a **contractual** basis (CPI/annual/index escalation, a cap, a cited clause) | Handed to Agent Bricks to verify against the real contract |
| `CLERK_REVIEW` | No valid authorization, an unconfirmable claim, a structural gap (missing PO/GRN), or a suspected duplicate | Routed to a human |

### Pipeline steps (`sql/`)
| File | What it does |
|---|---|
| `01_generate_data.sql` | Synthetic P2P data (15 vendors; PO/GRN/Invoice headers + lines) with deliberately seeded match failures. Pure SQL — runs on a serverless SQL warehouse. |
| `00_uc_functions.sql` | Governed Unity Catalog SQL functions used as tools — `get_tolerance` (VENDOR < CATEGORY < GLOBAL precedence) and the goods-receipt policy check. |
| `02_match_and_exceptions.sql` | Line-level 3-way match rolled up to invoice; all numeric deltas computed **deterministically** (the LLM never sizes them). Emits `g_match_exceptions`, the agent queue. |
| `03_ai_classify.sql` | **The hero step.** `ai_query` (Claude Sonnet, structured output) reads the full email thread + PO comment + invoice memo and assigns the disposition + business reason + `needs_contract_check`. Reads the whole chain — a later message can flip the conclusion. |
| `04_contract_validation.sql` | **Autonomous contract validation.** The Agent Bricks Supervisor (Knowledge Assistant over a contracts Volume) retrieves each vendor's price-escalation cap clause once per vendor; the pass/breach verdict is then computed deterministically per invoice. `WITHIN_CONTRACT` → auto-approve with cited clause; `BREACH` → clerk. |
| `05_duplicate_gate.sql` | Duplicate-invoice detection as a **set operation** (zero LLM tokens): blocking + fuzzy match within blocks, stamps duplicate risk and forces a hard payment hold. |
| `06_approvals_and_audit.sql` | Maker-checker approval store + append-only audit log; created idempotently so re-runs don't wipe decisions. |

### Data generators
- `gen_threads.py` — for 15 hand-picked exceptions (spanning every disposition), calls `ai_query` to author realistic, messy multi-message **email threads** + PO comments + invoice memos grounded on each invoice's facts. Some are written so a *later* message flips the conclusion — forcing the classifier to read the whole chain.
- `gen_contracts.py` — generates per-vendor Master Service Agreements (markdown) into a UC Volume, each with a **vendor-specific price-escalation cap**, so the same % increase is compliant for one vendor and a breach for another. The contract check must actually *read* the clause.

### The app (`app/`)
A Databricks App — **FastAPI backend + React/Vite frontend** — that lets an AP user work the exceptions queue, see each invoice's disposition and evidence, and action maker-checker approvals. Its **"Ask" widget** is powered by the same Agent Bricks Supervisor used in the pipeline, routing questions to a **Genie space** (data questions over the P2P gold tables) or the **Knowledge Assistant** (contract/clause questions) and synthesizing the answer (streamed live).

---

## Tech stack

- **Databricks AI Functions** — `ai_query` with Claude Sonnet and structured (`STRUCT`) output for classification and extraction.
- **Agent Bricks** — a multi-agent Supervisor (`mas-…-endpoint`) fronting a Knowledge Assistant (Vector Search over the contracts Volume) and a Genie space.
- **Unity Catalog** — governed SQL functions as tools, plus catalog/schema/Volume governance.
- **Serverless SQL** — the whole pipeline is SQL, so it runs on a warehouse (no DLT `ai_*` limitations).
- **Databricks Apps** — FastAPI + React front end with dual-mode auth (App service principal in-workspace; local profile for dev).

Environment (defaults): profile `fevm-lakemeter-demo`, catalog `lakemeter_demo_catalog`, schema `three_way_match`.

---

## Running it

**Prerequisites:** a Databricks CLI profile with access to the target workspace, a serverless SQL warehouse, and the Agent Bricks Supervisor endpoint + Genie space provisioned. Data volumes are tiny (≈308 invoices / 188 exceptions / 15 rich threads).

1. **Generate the pipeline data & run the steps** — either run the SQL files in order with the helper, or deploy the job in `resources/job.json`:
   ```bash
   python run_sql.py sql/01_generate_data.sql sql/00_uc_functions.sql sql/02_match_and_exceptions.sql \
                     sql/03_ai_classify.sql sql/04_contract_validation.sql \
                     sql/05_duplicate_gate.sql sql/06_approvals_and_audit.sql
   python gen_threads.py     # author the rich email threads (writes showcase_threads)
   python gen_contracts.py   # write per-vendor contracts into the UC Volume
   ```
   The 7-task Lakeflow job (`resources/job.json`) runs the same steps end-to-end; wall-clock ≈ 6–10 min, dominated by the AI classify step.

2. **Run the app locally:**
   ```bash
   cd app/frontend && npm install && npm run build && cd ..
   pip install -r requirements.txt
   uvicorn app:app --host 0.0.0.0 --port 8000   # then open http://localhost:8000
   ```
   Or deploy as a Databricks App using `app/app.yaml`.

---

## Sizing

See [`docs/diagrams/sizing.md`](docs/diagrams/sizing.md) for the approximate cost breakdown of this demo (serverless SQL minutes + pay-per-token model calls + always-on serving/app endpoints dominate; data size is negligible).

## Repository layout

```
sql/          7-step pipeline (00–06), pure SQL
gen_threads.py / gen_contracts.py   synthetic unstructured artifacts
run_sql.py    helper to execute .sql files against the warehouse
resources/    job.json — the 7-task Lakeflow job definition
app/          Databricks App (FastAPI backend + React frontend)
docs/         architecture diagrams + sizing
```

> Demo/showcase asset. Uses fully synthetic vendors, invoices, contracts and email threads — no real data.
