"""3-Way Match Failure Resolution Agent — FastAPI backend + static React frontend.

Reads the pipeline's gold/exception tables and the resolution-state view, and
lets an approver approve/reject routed exceptions (maker-checker) which advances
the state machine. All backed by Delta tables via the SQL warehouse.
"""
import os
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from databricks.sdk.service.sql import StatementParameterListItem as P

from backend.config import fq
from backend.db import query, execute, new_id

app = FastAPI(title="3-Way Match Agent")


# ─────────────────────────── API: metrics ───────────────────────────
@app.get("/api/metrics")
def metrics():
    total = query(f"SELECT count(*) c, coalesce(round(sum(invoice_amount),0),0) amt FROM {fq('gold_fact_invoices')}")[0]
    matched = query(f"SELECT count(*) c FROM {fq('gold_fact_invoices')} WHERE match_status='THREE_WAY_MATCHED'")[0]
    by_disp = query(f"""
        SELECT disposition, count(*) n,
               sum(CASE WHEN cleared_for_payment THEN 1 ELSE 0 END) cleared
        FROM {fq('v_resolution_state')} GROUP BY disposition""")
    d = {r["disposition"]: r for r in by_disp}
    def dn(k): return int(d[k]["n"]) if k in d else 0
    total_inv = int(total["c"])
    matched_n = int(matched["c"])
    touchless_auto = dn("TOUCHLESS_AUTO_APPROVE")
    email_ev = dn("EMAIL_EVIDENCE_APPROVE")
    # contract lane: split by verdict
    contract = query(f"""
        SELECT contract_verdict v, count(*) n FROM {fq('v_resolution_state')}
        WHERE disposition = 'CONTRACT_CHECK_NEEDED' GROUP BY contract_verdict""")
    cv = {r["v"]: int(r["n"]) for r in contract}
    contract_approved = cv.get("WITHIN_CONTRACT", 0)
    contract_breach = cv.get("BREACH", 0)
    contract_pending = cv.get(None, 0)
    # touchless = clean matches + email-evidence + contract-approved (all cleared, no human)
    touchless = matched_n + touchless_auto + email_ev + contract_approved
    baseline = matched_n  # deterministic 3-way match alone
    touchless_rate = round(touchless / max(total_inv, 1) * 100, 1)
    baseline_pct = round(baseline / max(total_inv, 1) * 100, 1)
    clerk_queue = dn("CLERK_REVIEW") + contract_breach

    # ── Evidence an AP Head would defend (money + effort, each verifiable) ──
    ev = query(f"""
        SELECT
          -- duplicate double-payments blocked before the payment run
          coalesce(round(sum(CASE WHEN payment_hold THEN invoice_amount END),0),0)          AS dup_blocked_inr,
          coalesce(sum(CASE WHEN payment_hold THEN 1 ELSE 0 END),0)                          AS dup_blocked_n,
          -- contract-breach invoices held: an increase over the vendor cap that sits UNDER
          -- the blunt 5% AP tolerance band — a rules engine would have paid these in full
          coalesce(round(sum(CASE WHEN contract_verdict='BREACH' THEN invoice_amount END),0),0) AS breach_held_inr,
          coalesce(sum(CASE WHEN contract_verdict='BREACH' THEN 1 ELSE 0 END),0)             AS breach_held_n,
          -- invoices cleared with NO person involved
          coalesce(sum(CASE WHEN cleared_for_payment THEN 1 ELSE 0 END),0)                   AS cleared_no_human,
          -- of those, how many carry a stored reason or cited clause (audit coverage)
          coalesce(sum(CASE WHEN cleared_for_payment AND (evidence_reason IS NOT NULL OR contract_clause IS NOT NULL) THEN 1 ELSE 0 END),0) AS cleared_with_evidence
        FROM {fq('v_resolution_state')}""")[0]
    dup_blocked_n = int(ev["dup_blocked_n"]); breach_held_n = int(ev["breach_held_n"])
    cleared_no_human = int(ev["cleared_no_human"]); cleared_with_ev = int(ev["cleared_with_evidence"])
    # exceptions a rules-engine sends to a person that the agent instead cleared with evidence
    reviews_removed = email_ev + contract_approved
    money_protected = float(ev["dup_blocked_inr"]) + float(ev["breach_held_inr"])
    # audit coverage: cleared invoices that needed evidence (exceptions, not clean matches)
    exceptions_cleared = touchless_auto + email_ev + contract_approved
    return {
        "total_invoices": total_inv,
        "total_amount": float(total["amt"]),
        "three_way_matched": matched_n,
        "email_evidence": email_ev,
        "contract_approved": contract_approved,
        "contract_breach": contract_breach,
        "contract_pending": contract_pending,
        "clerk_queue": clerk_queue,
        "touchless_rate": touchless_rate,
        "baseline_pct": baseline_pct,
        "uplift_pct": round(touchless_rate - baseline_pct, 1),
        # evidence block
        "money_protected": money_protected,
        "dup_blocked_inr": float(ev["dup_blocked_inr"]), "dup_blocked_n": dup_blocked_n,
        "breach_held_inr": float(ev["breach_held_inr"]), "breach_held_n": breach_held_n,
        "reviews_removed": reviews_removed,
        "cleared_no_human": cleared_no_human,
        "exceptions_cleared": exceptions_cleared,
        "audit_coverage_pct": round(cleared_with_ev / max(cleared_no_human, 1) * 100),
        "by_disposition": by_disp,
    }


# ─────────────────────────── API: exception queue ───────────────────────────
@app.get("/api/exceptions")
def exceptions(disposition: str = "all", scope: str = "showcase"):
    where = []
    params = []
    # Default to the curated showcase set: the invoices with rich, readable
    # multi-message threads. scope=all opens the full population.
    if scope == "showcase":
        where.append("is_showcase = true")
    if disposition != "all":
        where.append("disposition = :dp")
        params.append(P(name="dp", value=disposition))
    clause = ("WHERE " + " AND ".join(where)) if where else ""
    rows = query(f"""
        SELECT invoice_id, invoice_number, vendor_name, vendor_category, buyer_name,
               email_note, is_showcase, business_reason, invoice_amount, match_status,
               disposition, evidence_reason, classify_confidence, needs_contract_check,
               contract_verdict, contract_clause, contract_allowed_pct,
               price_variance_pct, qty_variance_pct,
               assigned_approver_role, agent_recommendation, effective_state,
               duplicate_of_invoice_id, duplicate_score, payment_hold, cleared_for_payment,
               decided_by
        FROM {fq('v_resolution_state')} {clause}
        ORDER BY CASE disposition
                   WHEN 'CONTRACT_CHECK_NEEDED' THEN 0
                   WHEN 'EMAIL_EVIDENCE_APPROVE' THEN 1
                   WHEN 'CLERK_REVIEW' THEN 2
                   ELSE 3 END,
                 invoice_amount DESC LIMIT 500""", params or None)
    return {"rows": rows, "count": len(rows)}


# ─────────────────────── API: hero moments (agentic proofs) ───────────────────
@app.get("/api/hero")
def hero():
    """The two 'not possible before' proofs, surfaced for the demo narrative."""
    # 1) Same price variance, opposite outcome — decided purely by the email text.
    #    One representative per disposition (dedup on price=18 pool).
    email_split = query(f"""
        WITH ranked AS (
          SELECT invoice_number, vendor_name, round(price_variance_pct,1) price_pct,
                 disposition, evidence_reason, effective_state, email_note,
                 row_number() OVER (PARTITION BY disposition ORDER BY invoice_amount DESC) rn
          FROM {fq('v_resolution_state')}
          WHERE round(price_variance_pct,0) = 18
            AND disposition IN ('EMAIL_EVIDENCE_APPROVE','CLERK_REVIEW')
        )
        SELECT invoice_number, vendor_name, price_pct, disposition, evidence_reason,
               effective_state, email_note
        FROM ranked WHERE rn = 1 ORDER BY disposition""")
    # 2) Contract check catches an overpayment that sits UNDER the 5% AP tolerance.
    #    One representative per verdict.
    contract_split = query(f"""
        WITH ranked AS (
          SELECT invoice_number, vendor_name, round(price_variance_pct,1) price_pct,
                 contract_allowed_pct, contract_verdict, effective_state, contract_clause,
                 row_number() OVER (PARTITION BY contract_verdict ORDER BY invoice_amount DESC) rn
          FROM {fq('v_resolution_state')}
          WHERE disposition = 'CONTRACT_CHECK_NEEDED' AND contract_verdict IS NOT NULL
        )
        SELECT invoice_number, vendor_name, price_pct, contract_allowed_pct,
               contract_verdict, effective_state, contract_clause
        FROM ranked WHERE rn = 1 ORDER BY contract_verdict""")
    return {"email_split": email_split, "contract_split": contract_split}


# ─────────────────────────── API: invoice detail ───────────────────────────
@app.get("/api/invoice/{invoice_id}")
def invoice_detail(invoice_id: str):
    p = [P(name="id", value=invoice_id)]
    head = query(f"SELECT * FROM {fq('v_resolution_state')} WHERE invoice_id = :id", p)
    if not head:
        raise HTTPException(404, "invoice not found")
    lines = query(f"""
        SELECT line_no, sku, invoiced_qty, ordered_qty, received_qty,
               invoiced_unit_price, po_unit_price,
               round(price_variance_pct*100,2) price_var_pct,
               round(qty_variance_pct*100,2) qty_var_pct
        FROM {fq('silver_match_lines')} WHERE invoice_id = :id ORDER BY line_no""", p)
    history = query(f"""
        SELECT action, approver, approver_role, note, decided_at
        FROM {fq('approval_decisions')} WHERE invoice_id = :id ORDER BY decided_at DESC""", p)
    return {"header": head[0], "lines": lines, "history": history}


# ─────────────────────────── API: approve / reject ───────────────────────────
class Decision(BaseModel):
    action: str            # APPROVE | REJECT
    approver: str = "approver@databricks.com"
    approver_role: str = "MANAGER"
    note: str = ""


@app.post("/api/invoice/{invoice_id}/decide")
def decide(invoice_id: str, d: Decision):
    action = d.action.upper()
    if action not in ("APPROVE", "REJECT"):
        raise HTTPException(400, "action must be APPROVE or REJECT")
    # Block approving an invoice on a hard duplicate payment hold.
    hold = query(f"SELECT payment_hold FROM {fq('v_resolution_state')} WHERE invoice_id = :id",
                 [P(name="id", value=invoice_id)])
    if not hold:
        raise HTTPException(404, "invoice not found")
    if action == "APPROVE" and bool(hold[0]["payment_hold"]):
        raise HTTPException(409, "Invoice is on a duplicate payment hold and cannot be approved.")

    did = new_id("D")
    ts = datetime.now(timezone.utc).isoformat()
    execute(f"""
        INSERT INTO {fq('approval_decisions')}
        (decision_id, invoice_id, action, approver, approver_role, note, decided_at)
        VALUES (:did, :iid, :act, :appr, :role, :note, :ts)""",
        [P(name="did", value=did), P(name="iid", value=invoice_id), P(name="act", value=action),
         P(name="appr", value=d.approver), P(name="role", value=d.approver_role),
         P(name="note", value=d.note), P(name="ts", value=ts)])
    execute(f"""
        INSERT INTO {fq('agent_decision_log')}
        (log_id, invoice_id, actor, event, detail, logged_at)
        VALUES (:lid, :iid, :appr, :evt, :det, :ts)""",
        [P(name="lid", value=new_id("L")), P(name="iid", value=invoice_id),
         P(name="appr", value=d.approver), P(name="evt", value=action + "D"),
         P(name="det", value=f"role={d.approver_role}; note={d.note}"), P(name="ts", value=ts)])
    return {"ok": True, "invoice_id": invoice_id, "action": action}


# ─────────── API: Ask-anything chat (Agent Bricks Supervisor) ───────────
# Same Supervisor that validates contracts in the pipeline: it routes data
# questions to the Genie space and contract questions to the Knowledge Assistant.
class ChatMsg(BaseModel):
    question: str
    history: list | None = None


# StreamingResponse + X-Accel-Buffering:no so the Databricks Apps proxy does not
# buffer SSE events before delivering them to the browser (typing effect).
_SSE_HEADERS = {
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache",
    "Connection": "keep-alive",
    "X-Accel-Buffering": "no",
}


@app.post("/api/chat")
def chat(m: ChatMsg):
    from backend.supervisor import stream
    return StreamingResponse(stream(m.question, m.history), headers=_SSE_HEADERS)


@app.get("/api/health")
def health():
    return {"ok": True}


# ─────────────────────────── static frontend ───────────────────────────
_dist = os.path.join(os.path.dirname(__file__), "frontend", "dist")
_shots = os.path.join(os.path.dirname(__file__), "screenshots")
if os.path.isdir(_shots):
    app.mount("/screenshots", StaticFiles(directory=_shots), name="screenshots")
if os.path.isdir(_dist):
    app.mount("/assets", StaticFiles(directory=os.path.join(_dist, "assets")), name="assets")

    @app.get("/{full_path:path}")
    def spa(full_path: str):
        return FileResponse(os.path.join(_dist, "index.html"))
