USE CATALOG lakemeter_demo_catalog;
USE SCHEMA three_way_match;

-- =============================================================================
-- 05_approvals_and_audit.sql — maker-checker approval store + append-only audit.
-- Created idempotently (IF NOT EXISTS) so pipeline re-runs don't wipe decisions.
-- The App reads g_match_exceptions and writes approval_decisions here; a view
-- projects the current state machine by folding decisions over the exception feed.
-- =============================================================================

-- ---- Approval decisions (maker-checker; append-only, latest wins) -----------
CREATE TABLE IF NOT EXISTS approval_decisions (
  decision_id      STRING,
  invoice_id       STRING,
  action           STRING,   -- 'APPROVE' | 'REJECT'
  approver         STRING,   -- who acted
  approver_role    STRING,
  note             STRING,
  decided_at       TIMESTAMP
);

-- ---- Audit log (every agent + human action, append-only) --------------------
CREATE TABLE IF NOT EXISTS agent_decision_log (
  log_id           STRING,
  invoice_id       STRING,
  actor            STRING,   -- 'AGENT' | approver id
  event            STRING,   -- CLASSIFIED / TOLERANCE_CHECKED / AUTO_RESOLVED / ROUTED / APPROVED / REJECTED
  detail           STRING,
  logged_at        TIMESTAMP
);

-- ---- Current-state view: fold latest human decision over the agent feed ------
-- Payment eligibility is explicit: an invoice is CLEARED_FOR_PAYMENT only when it
-- is auto-resolved OR approved, AND not on a duplicate payment hold.
CREATE OR REPLACE VIEW v_resolution_state AS
WITH latest AS (
  SELECT invoice_id, action, approver, decided_at,
         row_number() OVER (PARTITION BY invoice_id ORDER BY decided_at DESC) AS rn
  FROM approval_decisions
)
SELECT
  e.invoice_id, e.invoice_number, e.po_id, e.vendor_id, e.vendor_name,
  e.vendor_category, e.buyer_name, e.cost_center,
  e.email_note,
  e.email_thread, e.po_comment, e.invoice_memo, e.is_showcase,
  e.invoice_amount, e.price_variance_pct, e.qty_variance_pct, e.amount_delta_inr,
  e.match_status, e.match_finding, e.leg_po_ok, e.leg_grn_ok, e.leg_amount_ok,
  -- AI Classify outputs
  e.disposition, e.evidence_reason, e.business_reason, e.needs_contract_check, e.classify_confidence,
  -- Contract validation outputs
  e.contract_verdict, e.contract_clause, e.contract_allowed_pct,
  e.assigned_approver_role,
  e.agent_recommendation, e.agent_rationale,
  e.duplicate_of_invoice_id, e.duplicate_score, e.payment_hold,
  l.action AS human_action, l.approver AS decided_by,
  -- effective state machine (driven by disposition + contract verdict + human action)
  CASE
    WHEN e.resolution_state = 'AUTO_RESOLVED'                 THEN 'AUTO_RESOLVED'
    WHEN e.resolution_state = 'CONTRACT_PENDING'             THEN 'CONTRACT_PENDING'
    WHEN l.action = 'APPROVE'                                 THEN 'APPROVED'
    WHEN l.action = 'REJECT'                                  THEN 'REJECTED'
    ELSE 'PENDING_APPROVAL'
  END                                                          AS effective_state,
  CASE
    WHEN e.payment_hold                                        THEN false
    WHEN e.resolution_state = 'AUTO_RESOLVED'                 THEN true
    WHEN l.action = 'APPROVE'                                 THEN true
    ELSE false
  END                                                          AS cleared_for_payment
FROM g_match_exceptions e
LEFT JOIN latest l ON l.invoice_id = e.invoice_id AND l.rn = 1;

-- ---- Also project clean 3-way matches as cleared (for a full payment picture)-
CREATE OR REPLACE VIEW v_payment_ready AS
SELECT invoice_id, invoice_number, vendor_name, invoice_amount, 'THREE_WAY_MATCHED' AS source
FROM gold_fact_invoices WHERE match_status = 'THREE_WAY_MATCHED'
UNION ALL
SELECT invoice_id, invoice_number, vendor_name, invoice_amount, effective_state
FROM v_resolution_state WHERE cleared_for_payment = true;

SELECT effective_state, count(*) n, sum(CASE WHEN cleared_for_payment THEN 1 ELSE 0 END) cleared
FROM v_resolution_state GROUP BY effective_state ORDER BY n DESC;