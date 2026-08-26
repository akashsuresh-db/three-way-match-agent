USE CATALOG lakemeter_demo_catalog;
USE SCHEMA three_way_match;

-- =============================================================================
-- 02_match_and_exceptions.sql — 3-way match at line level, rolled up to invoice.
-- Produces:
--   silver_match_lines     : per invoice line, PO/GRN joined + deltas
--   gold_fact_invoices     : per invoice, amounts + match_status + deltas
--   g_match_exceptions     : failed invoices only, with approver context (agent queue)
-- All numeric deltas computed deterministically in SQL — the LLM never sizes them.
-- =============================================================================

-- ---- Line-level match --------------------------------------------------------
CREATE OR REPLACE TABLE silver_match_lines AS
SELECT
  il.invoice_id,
  ih.po_id,
  il.line_no,
  il.sku,
  -- quantities
  il.invoiced_qty,
  pol.ordered_qty,
  grn.received_qty,
  -- prices
  il.invoiced_unit_price,
  pol.po_unit_price,
  -- amounts
  round(il.invoiced_qty * il.invoiced_unit_price, 2)                    AS invoice_line_amount,
  round(pol.ordered_qty * pol.po_unit_price, 2)                         AS po_line_amount,
  -- deltas (fractions; NULL-safe)
  CASE WHEN pol.po_unit_price IS NOT NULL AND pol.po_unit_price <> 0
       THEN (il.invoiced_unit_price - pol.po_unit_price) / pol.po_unit_price END AS price_variance_pct,
  CASE WHEN grn.received_qty IS NOT NULL AND grn.received_qty <> 0
       THEN (il.invoiced_qty - grn.received_qty) / grn.received_qty
       WHEN pol.ordered_qty IS NOT NULL AND pol.ordered_qty <> 0
       THEN (il.invoiced_qty - pol.ordered_qty) / pol.ordered_qty END   AS qty_variance_pct,
  (grn.received_qty IS NOT NULL)                                        AS line_has_grn,
  CASE WHEN grn.received_qty IS NOT NULL AND pol.ordered_qty IS NOT NULL
            AND grn.received_qty < pol.ordered_qty THEN true ELSE false END AS line_gr_partial
FROM bronze_invoice_line il
JOIN bronze_invoice_header ih ON ih.invoice_id = il.invoice_id
LEFT JOIN bronze_po_line pol ON pol.po_id = ih.po_id AND pol.line_no = il.line_no
LEFT JOIN bronze_grn_line grn ON grn.po_id = ih.po_id AND grn.line_no = il.line_no;

-- ---- Invoice-level rollup + match status ------------------------------------
CREATE OR REPLACE TABLE gold_fact_invoices AS
WITH agg AS (
  SELECT
    ml.invoice_id,
    max(ml.po_id)                                     AS po_id,
    sum(ml.invoice_line_amount)                       AS invoice_amount,
    sum(ml.po_line_amount)                            AS po_amount,
    -- worst-case (max abs) variances across lines, keeping sign
    max(abs(coalesce(ml.price_variance_pct,0)))       AS max_abs_price_var,
    max(abs(coalesce(ml.qty_variance_pct,0)))         AS max_abs_qty_var,
    max(coalesce(ml.price_variance_pct,0))            AS price_variance_pct,
    max(coalesce(ml.qty_variance_pct,0))              AS qty_variance_pct,
    max(CASE WHEN ml.line_has_grn THEN 1 ELSE 0 END)  AS any_grn,
    min(CASE WHEN ml.line_has_grn THEN 1 ELSE 0 END)  AS all_grn,
    max(CASE WHEN ml.line_gr_partial THEN 1 ELSE 0 END) AS any_partial,
    count(*)                                          AS line_count,
    sum(CASE WHEN ml.po_unit_price IS NULL THEN 1 ELSE 0 END) AS lines_without_po
  FROM silver_match_lines ml
  GROUP BY ml.invoice_id
)
SELECT
  ih.invoice_id,
  ih.invoice_number,
  ih.po_id,
  ih.vendor_id,
  vm.vendor_name,
  vm.vendor_category,
  vm.vendor_tier,
  ph.buyer_id,
  bm.buyer_name,
  bm.cost_center,
  bm.approver_role                                    AS default_approver_role,
  bm.approver_email_local,
  ih.invoice_date,
  ih.due_date,
  ih.invoice_status,
  ih.email_note,
  coalesce(a.invoice_amount,0)                        AS invoice_amount,
  coalesce(a.po_amount,0)                             AS po_amount,
  a.price_variance_pct,
  a.qty_variance_pct,
  (ih.po_id IS NOT NULL)                              AS has_po_ref,
  (a.any_grn = 1)                                     AS has_grn,
  (a.any_partial = 1)                                 AS has_partial_grn,
  -- match_status: priority order (structural failures first, then variances)
  CASE
    WHEN ih.po_id IS NULL OR a.lines_without_po = a.line_count THEN 'NO_PO_REFERENCE'
    WHEN a.any_grn = 0                                            THEN 'GR_MISSING'
    WHEN a.max_abs_price_var >= 0.005 OR a.max_abs_qty_var >= 0.005 THEN 'AMOUNT_MISMATCH'
    WHEN a.any_partial = 1                                        THEN 'GR_PARTIAL'
    ELSE 'THREE_WAY_MATCHED'
  END                                                 AS match_status,
  -- ── Level-1 DETERMINISTIC finding: which leg of the 3-way broke, in plain SQL ──
  -- Computed before any AI runs; this is where the AI classification starts from.
  CASE
    WHEN ih.po_id IS NULL OR a.lines_without_po = a.line_count
      THEN 'No purchase order referenced — invoice cannot be matched to a PO.'
    WHEN a.any_grn = 0
      THEN 'No goods receipt found for this PO — nothing confirmed as received.'
    WHEN a.max_abs_price_var >= 0.005
      THEN concat('Invoiced unit price is ', round(a.max_abs_price_var*100,1),
                  '% above the PO price (invoice ', cast(round(a.invoice_amount,0) AS string),
                  ' vs PO ', cast(round(a.po_amount,0) AS string), ').')
    WHEN a.max_abs_qty_var >= 0.005
      THEN concat('Invoiced quantity is ', round(a.max_abs_qty_var*100,1),
                  '% above the quantity received on the goods receipt.')
    WHEN a.any_partial = 1
      THEN 'Goods receipt is partial — less was received than ordered.'
    ELSE 'Invoice, PO and goods receipt agree.'
  END                                                 AS match_finding,
  -- which legs are present (for the 3-way match tri-state chip in the UI)
  (ih.po_id IS NOT NULL)                              AS leg_po_ok,
  (a.any_grn = 1)                                     AS leg_grn_ok,
  (a.max_abs_price_var < 0.005 AND a.max_abs_qty_var < 0.005 AND a.any_partial = 0) AS leg_amount_ok,
  current_timestamp()                                 AS _processed_at
FROM bronze_invoice_header ih
LEFT JOIN agg a          ON a.invoice_id = ih.invoice_id
LEFT JOIN bronze_vendor_master vm ON vm.vendor_id = ih.vendor_id
LEFT JOIN bronze_po_header ph     ON ph.po_id = ih.po_id
LEFT JOIN bronze_buyer_master bm  ON bm.buyer_id = ph.buyer_id;

-- ---- Exception feed (agent queue): everything that is NOT clean-matched ------
-- resolution_state starts at NEW; the classify/tolerance/decision steps advance it.
CREATE OR REPLACE TABLE g_match_exceptions AS
SELECT
  g.invoice_id, invoice_number, po_id, vendor_id, vendor_name, vendor_category,
  vendor_tier, buyer_id, buyer_name, cost_center, default_approver_role,
  approver_email_local, invoice_date, due_date,
  email_note,                                         -- short fallback note
  -- ── rich unstructured artifacts the AI reads (showcase invoices) ──
  st.email_thread, st.po_comment, st.invoice_memo,
  (st.invoice_id IS NOT NULL)                         AS is_showcase,
  -- ── Level-1 deterministic finding (computed in SQL, before AI) ──
  match_finding, leg_po_ok, leg_grn_ok, leg_amount_ok,
  invoice_amount, po_amount,
  round(coalesce(price_variance_pct,0)*100, 2)        AS price_variance_pct,
  round(coalesce(qty_variance_pct,0)*100, 2)          AS qty_variance_pct,
  round(invoice_amount - po_amount, 2)                AS amount_delta_inr,
  has_po_ref, has_grn, has_partial_grn,
  match_status,
  'NEW'                                               AS resolution_state,
  -- ── AI Classify outputs (set by step 03) ──
  cast(NULL AS string)                                AS disposition,        -- TOUCHLESS_AUTO_APPROVE | EMAIL_EVIDENCE_APPROVE | CONTRACT_CHECK_NEEDED | CLERK_REVIEW
  cast(NULL AS string)                                AS evidence_reason,    -- extracted approval/dispute reason (audit)
  cast(NULL AS string)                                AS business_reason,    -- the specific cause the AI found in the chain
  cast(NULL AS boolean)                               AS needs_contract_check,
  cast(NULL AS double)                                AS classify_confidence,
  cast(NULL AS string)                                AS mismatch_type,      -- legacy mechanical label (kept for reference)
  cast(NULL AS string)                                AS classify_reason,
  -- ── Contract validation outputs (set by step 04, Agent Bricks) ──
  cast(NULL AS string)                                AS contract_verdict,   -- WITHIN_CONTRACT | BREACH | (null)
  cast(NULL AS string)                                AS contract_clause,    -- cited clause text
  cast(NULL AS double)                                AS contract_allowed_pct,
  cast(NULL AS double)                                AS applied_tolerance_pct,
  cast(NULL AS string)                                AS applied_rule_id,
  cast(NULL AS string)                                AS assigned_approver_role,
  cast(NULL AS string)                                AS agent_recommendation,
  cast(NULL AS string)                                AS agent_rationale,
  cast(NULL AS string)                                AS duplicate_of_invoice_id,
  cast(NULL AS double)                                AS duplicate_score,
  cast(false AS boolean)                              AS payment_hold,
  current_timestamp()                                 AS _created_at
FROM gold_fact_invoices g
LEFT JOIN showcase_threads st ON st.invoice_id = g.invoice_id
WHERE match_status <> 'THREE_WAY_MATCHED';

-- ---- Distribution check ------------------------------------------------------
SELECT match_status, count(*) AS invoices,
       round(sum(invoice_amount),0) AS total_amount
FROM gold_fact_invoices
GROUP BY match_status ORDER BY invoices DESC;