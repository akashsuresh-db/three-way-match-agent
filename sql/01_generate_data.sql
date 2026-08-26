USE CATALOG lakemeter_demo_catalog;
USE SCHEMA three_way_match;

-- =============================================================================
-- 01_generate_data.sql — Synthetic P2P data with deliberately seeded 3-way match
-- failures. Pure SQL so it runs on serverless SQL warehouse (no DLT ai_* limits).
-- Grain: header + line tables for PO, GRN, Invoice. Masters for vendor & buyer.
-- =============================================================================

-- ---- Vendor master -----------------------------------------------------------
CREATE OR REPLACE TABLE bronze_vendor_master AS
SELECT
  concat('V', lpad(cast(id AS string), 4, '0'))                       AS vendor_id,
  element_at(array('Acme Components','Globex Supplies','Initech Systems',
    'Umbrella Materials','Stark Industrial','Wayne Logistics','Wonka Packaging',
    'Cyberdyne Parts','Soylent Foods','Hooli Cloud','Pied Piper Data',
    'Vandelay Imports','Massive Dynamic','Gekko Capital Goods','Nakatomi Trading'),
    cast(id AS int))                                                  AS vendor_name,
  element_at(array('IT_HARDWARE','MRO','LOGISTICS','PACKAGING','RAW_MATERIALS',
    'IT_HARDWARE','SERVICES','MRO','RAW_MATERIALS','SERVICES','SERVICES',
    'PACKAGING','IT_HARDWARE','MRO','LOGISTICS'), cast(id AS int))    AS vendor_category,
  element_at(array('STRATEGIC','PREFERRED','STANDARD'),
    cast(pmod(id,3)+1 AS int))                                        AS vendor_tier,
  concat('27', lpad(cast(id*7 AS string),9,'0'), 'Z',
    cast(pmod(id,9)+1 AS string))                                     AS gstin,
  true                                                                AS is_active
FROM range(1,16) AS t(id);

-- ---- Buyer / cost-center master ---------------------------------------------
CREATE OR REPLACE TABLE bronze_buyer_master AS
SELECT
  concat('B', lpad(cast(id AS string),3,'0'))                         AS buyer_id,
  element_at(array('Priya Nair','Marcus Chen','Elena Rossi','David Okafor',
    'Sara Kim','Tomás Alvarez'), cast(id AS int))                     AS buyer_name,
  element_at(array('CC-OPS-100','CC-IT-200','CC-MFG-300','CC-LOG-400',
    'CC-FAC-500','CC-PROC-600'), cast(id AS int))                     AS cost_center,
  element_at(array('MANAGER','MANAGER','DIRECTOR','MANAGER','DIRECTOR','VP'),
    cast(id AS int))                                                  AS approver_role,
  element_at(array('priya.nair','marcus.chen','elena.rossi','david.okafor',
    'sara.kim','tomas.alvarez'), cast(id AS int))                     AS approver_email_local
FROM range(1,7) AS t(id);

-- ---- PO headers --------------------------------------------------------------
-- 300 POs, each tied to a vendor and buyer round-robin.
CREATE OR REPLACE TABLE bronze_po_header AS
SELECT
  concat('PO', lpad(cast(id AS string),6,'0'))                        AS po_id,
  concat('V', lpad(cast(pmod(id,15)+1 AS string),4,'0'))              AS vendor_id,
  concat('B', lpad(cast(pmod(id,6)+1 AS string),3,'0'))               AS buyer_id,
  date_add('2026-01-01', cast(pmod(id*3,150) AS int))                 AS po_date,
  'OPEN'                                                              AS po_status
FROM range(1,301) AS t(id);

-- ---- PO lines ----------------------------------------------------------------
-- 1–3 lines per PO. Deterministic qty & unit price from ids.
CREATE OR REPLACE TABLE bronze_po_line AS
SELECT
  h.po_id,
  ln                                                                  AS line_no,
  concat('SKU', lpad(cast(pmod(cast(substr(h.po_id,3) AS int)*7+ln,120) AS string),4,'0')) AS sku,
  cast(10 + pmod(cast(substr(h.po_id,3) AS int)*3+ln, 90) AS int)     AS ordered_qty,
  round(100 + pmod(cast(substr(h.po_id,3) AS int)*13+ln*7, 900) + 0.50, 2) AS po_unit_price
FROM bronze_po_header h
LATERAL VIEW explode(sequence(1, cast(pmod(cast(substr(h.po_id,3) AS int),3)+1 AS int))) t AS ln;

-- ---- GRN lines (goods receipts) ---------------------------------------------
-- Most POs fully received. Seeded exceptions:
--   po ending 0 -> NO GRN at all (GR_MISSING)
--   po ending 5 -> partial receipt (GR_PARTIAL): received_qty < ordered_qty
-- others -> full receipt matching ordered_qty
CREATE OR REPLACE TABLE bronze_grn_line AS
SELECT
  p.po_id,
  p.line_no,
  p.sku,
  CASE
    WHEN pmod(cast(substr(p.po_id,3) AS int),10) = 5
      THEN cast(round(p.ordered_qty * 0.6) AS int)      -- partial
    ELSE p.ordered_qty                                   -- full
  END                                                    AS received_qty,
  date_add('2026-01-05', cast(pmod(cast(substr(p.po_id,3) AS int)*3,150) AS int)) AS grn_date,
  'ACCEPTED'                                             AS quality_status
FROM bronze_po_line p
WHERE pmod(cast(substr(p.po_id,3) AS int),10) <> 0;      -- po ending 0 => no GRN rows

-- ---- Invoice headers ---------------------------------------------------------
-- One invoice per PO (ids 1..300). Then append duplicates (ids 301+).
-- Seeded header-level exceptions:
--   po ending 3 -> NO_PO reference on invoice (po_id blanked)
--
-- email_note: FREE TEXT that rides along with the invoice (buyer/supplier email).
-- This is the signal AI must interpret — deterministic SQL cannot read it. The note
-- is what flips the disposition. Keyed to the seeded exception type so the story is
-- stable but the *outcome* depends on the language, not the numbers:
--   price-large (ending 2): split by id — some carry an APPROVAL email (auto-approve
--     w/ audit reason), some claim a CONTRACT basis (needs contract lookup), some
--     have NO justification (clerk review). Same +18% delta, three destinations.
--   qty-variance (ending 6): buyer email pre-approving the extra units → email-approve.
--   price-small (ending 1): clean, no note → touchless.
CREATE OR REPLACE TABLE bronze_invoice_header AS
SELECT
  concat('INV', lpad(cast(id AS string),6,'0'))                       AS invoice_id,
  concat('INV', lpad(cast(id AS string),6,'0'))                       AS invoice_number,
  CASE WHEN pmod(id,10) = 3 THEN NULL
       ELSE concat('PO', lpad(cast(id AS string),6,'0')) END          AS po_id,
  concat('V', lpad(cast(pmod(id,15)+1 AS string),4,'0'))              AS vendor_id,
  date_add('2026-01-10', cast(pmod(id*3,150) AS int))                 AS invoice_date,
  date_add('2026-01-10', cast(pmod(id*3,150)+30 AS int))              AS due_date,
  'PENDING'                                                           AS invoice_status,
  CASE
    -- LARGE price variance (ending 2): 3-way fork based purely on the email text
    WHEN pmod(id,10) = 2 AND pmod(id,3) = 0 THEN
      'Hi AP team — please proceed with this invoice. We (procurement) approved the additional freight of about INR 2,500 because the shipment had to be air-freighted for the urgent line stoppage. Approval on file, go ahead and pay. — Buyer'
    WHEN pmod(id,10) = 2 AND pmod(id,3) = 1 THEN
      'Note from supplier: the higher unit price reflects our annual price escalation as per the master services agreement (CPI-linked uplift). Please refer to the contract for the agreed cap.'
    WHEN pmod(id,10) = 2 AND pmod(id,3) = 2 THEN
      'Supplier applied a rate increase this quarter. No amendment or approval has been shared with procurement for this change.'
    -- QUANTITY variance (ending 6): buyer pre-approved the extra units
    WHEN pmod(id,10) = 6 THEN
      'FYI — we asked the supplier to ship the extra units to cover the additional production run this month. The higher quantity on the invoice is expected and approved by the plant. — Buyer'
    -- SMALL price variance (ending 1) and everything else: no note (clean/touchless)
    ELSE NULL
  END                                                                 AS email_note
FROM range(1,301) AS t(id);

-- ---- Invoice lines -----------------------------------------------------------
-- Start from PO lines; inject price & qty variances by po id modulo. The price
-- increase is deliberately correlated with the email_note disposition (same seed):
--   ending 1              -> small +3% price, no note -> touchless
--   ending 2, mod3=0      -> +18% price, FREIGHT-APPROVE email      (email-evidence approve)
--   ending 2, mod3=2      -> +18% price, NO-JUSTIFICATION email     (clerk review)
--   ending 2, mod3=1      -> CONTRACT-BASIS email; increase sits WITHIN the blunt 5%
--                            AP tolerance but straddles the vendor's tighter contractual
--                            cap: +2.5% (mod20=2, within a 3% contract cap -> legit) vs
--                            +4% (mod20=12, breaches the 3% cap yet the AP tolerance band
--                            would have blindly auto-paid it -> the overpayment the
--                            contract check CATCHES).
--   ending 6              -> +15% quantity, buyer-approved-extra-units email
CREATE OR REPLACE TABLE bronze_invoice_line AS
SELECT
  concat('INV', lpad(cast(cast(substr(p.po_id,3) AS int) AS string),6,'0')) AS invoice_id,
  p.line_no,
  p.sku,
  -- invoiced quantity
  CASE
    WHEN pmod(cast(substr(p.po_id,3) AS int),10) = 6
      THEN cast(round(p.ordered_qty * 1.15) AS int)
    ELSE p.ordered_qty
  END                                                                 AS invoiced_qty,
  -- invoiced unit price
  round(
    CASE
      WHEN pmod(cast(substr(p.po_id,3) AS int),10) = 1 THEN p.po_unit_price * 1.03
      -- large, unambiguous over-billing (freight / no-justification lanes)
      WHEN pmod(cast(substr(p.po_id,3) AS int),10) = 2
           AND pmod(cast(substr(p.po_id,3) AS int),3) <> 1 THEN p.po_unit_price * 1.18
      -- contract-basis lane: modest increases that test the contractual cap
      WHEN pmod(cast(substr(p.po_id,3) AS int),20) = 2  THEN p.po_unit_price * 1.025  -- within 3% cap
      WHEN pmod(cast(substr(p.po_id,3) AS int),20) = 12 THEN p.po_unit_price * 1.040  -- breaches 3% cap
      ELSE p.po_unit_price
    END, 2)                                                           AS invoiced_unit_price
FROM bronze_po_line p;

-- ---- Duplicate invoices ------------------------------------------------------
-- Append near-duplicates of a handful of clean invoices: same vendor, same
-- amount, invoice_number with a trailing suffix, date shifted a few days.
-- These must be caught by the deterministic dedup gate (NOT by the LLM).
INSERT INTO bronze_invoice_header
SELECT
  concat('INV', lpad(cast(300 + row_number() OVER (ORDER BY invoice_id) AS string),6,'0')) AS invoice_id,
  concat(invoice_number, '-A')                                        AS invoice_number,
  po_id, vendor_id,
  date_add(invoice_date, 4)                                           AS invoice_date,
  date_add(due_date, 4)                                               AS due_date,
  'PENDING'                                                           AS invoice_status,
  'Re-sending our invoice as we have not received payment confirmation. Please process.' AS email_note
FROM bronze_invoice_header
WHERE pmod(cast(substr(invoice_id,4) AS int),10) = 7   -- clean ones (ending 7)
  AND po_id IS NOT NULL
LIMIT 8;

-- Duplicate their lines too (copy from the source invoice's lines).
INSERT INTO bronze_invoice_line
SELECT
  concat('INV', lpad(cast(300 + d.rn AS string),6,'0'))               AS invoice_id,
  l.line_no, l.sku, l.invoiced_qty, l.invoiced_unit_price
FROM (
  SELECT invoice_id,
         row_number() OVER (ORDER BY invoice_id) AS rn
  FROM bronze_invoice_header
  WHERE pmod(cast(substr(invoice_id,4) AS int),10) = 7
    AND po_id IS NOT NULL
    AND cast(substr(invoice_id,4) AS int) <= 300
  LIMIT 8
) d
JOIN bronze_invoice_line l ON l.invoice_id = d.invoice_id;

-- ---- Tolerance rules reference ----------------------------------------------
-- Data, not code. Keyed by (scope) x mismatch_type. Resolution precedence:
-- vendor-specific > category > global default (lower precedence number wins).
CREATE OR REPLACE TABLE ref_tolerance_rules (
  rule_id            STRING,
  scope_type         STRING,   -- 'VENDOR' | 'CATEGORY' | 'GLOBAL'
  scope_value        STRING,   -- vendor_id / category / '*'
  mismatch_type      STRING,   -- 'PRICE_VARIANCE'|'QUANTITY_VARIANCE'|'GR_PARTIAL'
  tolerance_pct      DOUBLE,   -- allowed variance as fraction (0.05 = 5%)
  auto_approve_ceiling_inr DOUBLE,
  required_approver_role STRING,
  precedence         INT
);

INSERT INTO ref_tolerance_rules VALUES
  ('R-GLOBAL-PRICE','GLOBAL','*','PRICE_VARIANCE',      0.05, 500000, 'MANAGER', 100),
  ('R-GLOBAL-QTY',  'GLOBAL','*','QUANTITY_VARIANCE',   0.05, 500000, 'MANAGER', 100),
  ('R-GLOBAL-GRP',  'GLOBAL','*','GR_PARTIAL',          0.10, 300000, 'MANAGER', 100),
  ('R-CAT-ITHW-PR', 'CATEGORY','IT_HARDWARE','PRICE_VARIANCE', 0.08, 800000, 'DIRECTOR', 50),
  ('R-CAT-RAW-PR',  'CATEGORY','RAW_MATERIALS','PRICE_VARIANCE',0.10, 600000, 'MANAGER', 50),
  ('R-VEND-V0001-PR','VENDOR','V0001','PRICE_VARIANCE', 0.12, 1000000,'DIRECTOR', 10);

-- ---- Quick sanity counts -----------------------------------------------------
SELECT 'vendors' AS t, count(*) c FROM bronze_vendor_master
UNION ALL SELECT 'buyers', count(*) FROM bronze_buyer_master
UNION ALL SELECT 'po_header', count(*) FROM bronze_po_header
UNION ALL SELECT 'po_line', count(*) FROM bronze_po_line
UNION ALL SELECT 'grn_line', count(*) FROM bronze_grn_line
UNION ALL SELECT 'invoice_header', count(*) FROM bronze_invoice_header
UNION ALL SELECT 'invoice_line', count(*) FROM bronze_invoice_line
UNION ALL SELECT 'tolerance_rules', count(*) FROM ref_tolerance_rules
ORDER BY t;