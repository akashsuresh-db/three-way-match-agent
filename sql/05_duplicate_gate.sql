USE CATALOG lakemeter_demo_catalog;
USE SCHEMA three_way_match;

-- =============================================================================
-- 04_duplicate_gate.sql — Duplicate-invoice detection as a SET operation.
-- ZERO LLM tokens: deterministic blocking + fuzzy match WITHIN blocks (not O(n^2)).
-- Runs over ALL invoices (not just exceptions), then stamps duplicate risk onto
-- g_match_exceptions and forces a hard payment_hold. This is the pre-payment gate.
-- =============================================================================

-- ---- Normalized dedup key over the full invoice set --------------------------
-- Block key = vendor + amount bucket (rounded to nearest 1000) + invoice month.
-- Within a block, two invoices are duplicates when the normalized invoice number
-- matches (strip non-alphanumerics + trailing -A/-1 style suffixes), amounts are
-- within 0.5%, and dates within 7 days. Earliest invoice_id = the "original".
CREATE OR REPLACE TABLE _invoice_dedup_base AS
SELECT
  gfi.invoice_id,
  gfi.invoice_number,
  gfi.vendor_id,
  gfi.invoice_date,
  gfi.invoice_amount,
  -- normalized number: uppercase, keep alphanumerics, then drop trailing letters
  -- that follow a digit (e.g. resubmit suffix -A -> A). Digits are preserved.
  regexp_replace(
    regexp_replace(upper(gfi.invoice_number), '[^A-Z0-9]', ''),
    '([0-9])[A-Z]+$', '$1'
  )                                                    AS norm_number,
  round(gfi.invoice_amount / 1000.0)                   AS amt_bucket,
  date_format(gfi.invoice_date, 'yyyyMM')              AS inv_month
FROM gold_fact_invoices gfi;

-- ---- Candidate duplicate pairs within blocks --------------------------------
CREATE OR REPLACE TABLE _duplicate_pairs AS
SELECT
  a.invoice_id                                         AS dup_invoice_id,
  b.invoice_id                                         AS original_invoice_id,
  a.invoice_amount,
  -- similarity score (deterministic): weighted amount closeness + date closeness
  round(
    0.6 * (1 - least(abs(a.invoice_amount - b.invoice_amount)
                     / greatest(a.invoice_amount,1), 1))
  + 0.4 * (1 - least(abs(datediff(a.invoice_date, b.invoice_date)) / 30.0, 1))
  , 4)                                                 AS duplicate_score
FROM _invoice_dedup_base a
JOIN _invoice_dedup_base b
  ON  a.vendor_id = b.vendor_id            -- same block: vendor
  AND a.amt_bucket = b.amt_bucket          -- same block: amount bucket
  AND a.norm_number = b.norm_number        -- normalized invoice number matches
  AND a.invoice_id > b.invoice_id          -- keep one direction; earlier = original
  AND abs(a.invoice_amount - b.invoice_amount) <= a.invoice_amount * 0.005
  AND abs(datediff(a.invoice_date, b.invoice_date)) <= 7;

-- keep the single best original per duplicate
CREATE OR REPLACE TABLE _duplicate_best AS
SELECT dup_invoice_id, original_invoice_id, duplicate_score
FROM (
  SELECT *, row_number() OVER (PARTITION BY dup_invoice_id
                               ORDER BY duplicate_score DESC) AS rn
  FROM _duplicate_pairs
) WHERE rn = 1;

-- ---- Stamp duplicate risk + payment hold onto the exception feed ------------
-- Ensure duplicates are present in the exception queue even if their match was
-- otherwise clean (a duplicate of a clean invoice must still be held).
MERGE INTO g_match_exceptions t
USING _duplicate_best d
ON t.invoice_id = d.dup_invoice_id
WHEN MATCHED THEN UPDATE SET
  t.duplicate_of_invoice_id = d.original_invoice_id,
  t.duplicate_score         = d.duplicate_score,
  t.payment_hold            = true,
  t.resolution_state        = 'PENDING_APPROVAL',
  t.disposition             = 'CLERK_REVIEW',
  t.mismatch_type           = 'DUPLICATE_SUSPECT',
  t.evidence_reason         = concat('Deterministic dedup gate: near-duplicate of ', d.original_invoice_id),
  t.business_reason         = concat('Duplicate resubmission of already-booked invoice ', d.original_invoice_id),
  t.assigned_approver_role  = coalesce(t.assigned_approver_role, t.default_approver_role),
  t.agent_recommendation    = concat('Potential duplicate of ', d.original_invoice_id,
                                     ' (score ', cast(round(d.duplicate_score,3) AS string),
                                     ') — HARD HOLD before payment run.'),
  t.agent_rationale         = concat('dedup: matched original ', d.original_invoice_id,
                                     ' via vendor+normalized-number+amount+date block');

-- Insert duplicates that were NOT already in the exception feed (clean matches).
-- Explicit column list => robust to table column ordering.
INSERT INTO g_match_exceptions (
  invoice_id, invoice_number, po_id, vendor_id, vendor_name, vendor_category,
  vendor_tier, buyer_id, buyer_name, cost_center, default_approver_role,
  approver_email_local, invoice_date, due_date, email_note,
  email_thread, po_comment, invoice_memo, is_showcase,
  match_finding, leg_po_ok, leg_grn_ok, leg_amount_ok,
  invoice_amount, po_amount,
  price_variance_pct, qty_variance_pct, amount_delta_inr, has_po_ref, has_grn,
  has_partial_grn, match_status, resolution_state, disposition, evidence_reason,
  business_reason, needs_contract_check, mismatch_type, assigned_approver_role,
  agent_recommendation, agent_rationale, duplicate_of_invoice_id, duplicate_score,
  payment_hold, _created_at
)
SELECT
  gfi.invoice_id, gfi.invoice_number, gfi.po_id, gfi.vendor_id, gfi.vendor_name,
  gfi.vendor_category, gfi.vendor_tier, gfi.buyer_id, gfi.buyer_name, gfi.cost_center,
  gfi.default_approver_role, gfi.approver_email_local, gfi.invoice_date, gfi.due_date,
  gfi.email_note,
  st.email_thread, st.po_comment, st.invoice_memo, (st.invoice_id IS NOT NULL),
  gfi.match_finding, gfi.leg_po_ok, gfi.leg_grn_ok, gfi.leg_amount_ok,
  gfi.invoice_amount, gfi.po_amount,
  round(coalesce(gfi.price_variance_pct,0)*100,2),
  round(coalesce(gfi.qty_variance_pct,0)*100,2),
  round(gfi.invoice_amount - gfi.po_amount,2),
  gfi.has_po_ref, gfi.has_grn, gfi.has_partial_grn,
  gfi.match_status,
  'PENDING_APPROVAL', 'CLERK_REVIEW',
  concat('Deterministic dedup gate: near-duplicate of ', d.original_invoice_id),
  concat('Duplicate resubmission of already-booked invoice ', d.original_invoice_id), false, 'DUPLICATE_SUSPECT',
  gfi.default_approver_role,
  concat('Potential duplicate of ', d.original_invoice_id,
         ' (score ', cast(round(d.duplicate_score,3) AS string),
         ') — HARD HOLD before payment run.'),
  concat('dedup: matched original ', d.original_invoice_id),
  d.original_invoice_id, d.duplicate_score, true, current_timestamp()
FROM _duplicate_best d
JOIN gold_fact_invoices gfi ON gfi.invoice_id = d.dup_invoice_id
LEFT JOIN showcase_threads st ON st.invoice_id = gfi.invoice_id
WHERE d.dup_invoice_id NOT IN (SELECT invoice_id FROM g_match_exceptions);

-- ---- Final state of the pipeline --------------------------------------------
SELECT resolution_state, mismatch_type,
       count(*) AS n,
       sum(CASE WHEN payment_hold THEN 1 ELSE 0 END) AS on_hold
FROM g_match_exceptions
GROUP BY resolution_state, mismatch_type
ORDER BY resolution_state, n DESC;