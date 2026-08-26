USE CATALOG lakemeter_demo_catalog;
USE SCHEMA three_way_match;

-- =============================================================================
-- 03_ai_classify.sql — THE HERO AI STEP (agent-native, email-aware).
--
-- ai_query (Claude, structured output) reads the free-text email_note that rides
-- with each invoice PLUS the numeric deltas, and autonomously assigns a business
-- DISPOSITION. This is signal deterministic SQL cannot process: two invoices with
-- an identical +18% delta go to different lanes purely because of the email text.
--
-- Dispositions (4 lanes):
--   TOUCHLESS_AUTO_APPROVE  clean / trivial / within tolerance, no ambiguity
--   EMAIL_EVIDENCE_APPROVE  the email authorises the delta -> auto-approve + record
--                           the extracted reason for audit
--   CONTRACT_CHECK_NEEDED   the increase claims a contractual basis -> must retrieve
--                           and validate the contract clause (step 04, Agent Bricks)
--   CLERK_REVIEW            genuine violation / no evidence -> route to AP clerk
--
-- The model also returns needs_contract_check so the pipeline knows which invoices
-- to hand to the Agent Bricks Supervisor. No CASE statement decides the lane — the
-- LLM does, from the language.
-- =============================================================================

CREATE OR REPLACE TABLE _exceptions_ai AS
SELECT
  *,
  ai_query(
    'databricks-claude-sonnet-4-5',
    concat(
      'You are an accounts-payable exceptions analyst. An invoice failed 3-way match. ',
      'You are given the FULL unstructured record that came with it: the complete email thread ',
      '(which may have several messages, quoted replies and follow-ups), a comment left on the ',
      'purchase order, and a memo on the invoice itself. ',
      'Read the ENTIRE chain before deciding — the true intent is often in a LATER message, not the ',
      'first one. A supplier may CLAIM approval that a follow-up then denies; an initial dispute may ',
      'be RESOLVED by a later sign-off. Weigh the final, authoritative state of the conversation. ',
      'Then decide the disposition and, importantly, state the SPECIFIC business reason for the ',
      'exception (what actually happened, in one plain sentence — e.g. "air-freight premium approved ',
      'by Plant Director per incident INC-4421", not a generic label). ',
      'Dispositions: ',
      '- TOUCHLESS_AUTO_APPROVE: within tolerance / no ambiguity, no action needed. ',
      '- EMAIL_EVIDENCE_APPROVE: the chain contains genuine, identifiable written authorisation for the ',
      '  extra cost or quantity (a named approver, an SOW change, a documented pre-approval). ',
      '- CONTRACT_CHECK_NEEDED: the price increase is justified by a CONTRACTUAL basis (annual/CPI/index ',
      '  escalation, a cap, a cited clause or amendment). Set needs_contract_check=true — the clause must ',
      '  be verified against the vendor agreement; do NOT approve on the supplier''s word alone. ',
      '- CLERK_REVIEW: no valid authorisation, a claimed approval that cannot be confirmed / is denied, ',
      '  missing PO or goods receipt, an unexplained quantity, or a suspected duplicate. ',
      'IMPORTANT: a structural gap — no PO on the invoice, or no goods receipt posted — is always ',
      'CLERK_REVIEW even if someone promises to raise a retroactive PO or confirm delivery later. A ',
      'promise to fix paperwork is not an authorisation to pay now; only an existing, documented ',
      'approval of the CHARGE counts as EMAIL_EVIDENCE_APPROVE. ',
      'evidence_reason: short audit-log justification for the disposition. ',
      'Structured facts (context only): ',
      'match_status=', coalesce(match_status,''),
      '; price_variance_pct=', cast(coalesce(price_variance_pct,0) AS string),
      '; qty_variance_pct=', cast(coalesce(qty_variance_pct,0) AS string),
      '; has_po_ref=', cast(has_po_ref AS string),
      '; has_grn=', cast(has_grn AS string),
      '; vendor=', coalesce(vendor_name,''),
      '. --- EMAIL THREAD ---\n', coalesce(email_thread, email_note, '(none)'),
      '\n--- PO COMMENT ---\n', coalesce(po_comment, '(none)'),
      '\n--- INVOICE MEMO ---\n', coalesce(invoice_memo, '(none)')
    ),
    responseFormat =>
      'STRUCT<result:STRUCT<disposition:STRING, business_reason:STRING, evidence_reason:STRING, needs_contract_check:BOOLEAN, confidence:DOUBLE>>'
  )                                                    AS ai_raw
FROM g_match_exceptions;

-- Parse the struct and merge back into g_match_exceptions.
CREATE OR REPLACE TABLE g_match_exceptions AS
WITH classified AS (
  SELECT
    e.* EXCEPT (disposition, evidence_reason, business_reason, needs_contract_check,
                classify_confidence, resolution_state, assigned_approver_role,
                agent_recommendation, agent_rationale, ai_raw),
    from_json(e.ai_raw,
      'STRUCT<disposition:STRING, business_reason:STRING, evidence_reason:STRING, needs_contract_check:BOOLEAN, confidence:DOUBLE>'
    )                                                  AS ai
  FROM _exceptions_ai e
)
SELECT
  c.* EXCEPT (ai),
  c.ai.disposition                                     AS disposition,
  c.ai.evidence_reason                                 AS evidence_reason,
  c.ai.business_reason                                 AS business_reason,
  coalesce(c.ai.needs_contract_check, false)           AS needs_contract_check,
  c.ai.confidence                                      AS classify_confidence,
  -- resolution_state provisional from the AI lane; step 04 finalises contract cases.
  CASE
    WHEN c.ai.disposition = 'TOUCHLESS_AUTO_APPROVE' THEN 'AUTO_RESOLVED'
    WHEN c.ai.disposition = 'EMAIL_EVIDENCE_APPROVE' THEN 'AUTO_RESOLVED'
    WHEN c.ai.disposition = 'CONTRACT_CHECK_NEEDED'  THEN 'CONTRACT_PENDING'
    ELSE 'PENDING_APPROVAL'
  END                                                  AS resolution_state,
  CASE
    WHEN c.ai.disposition IN ('TOUCHLESS_AUTO_APPROVE','EMAIL_EVIDENCE_APPROVE') THEN NULL
    ELSE c.default_approver_role
  END                                                  AS assigned_approver_role,
  CASE
    WHEN c.ai.disposition = 'TOUCHLESS_AUTO_APPROVE' THEN 'Auto-approved — no exception evidence needed.'
    WHEN c.ai.disposition = 'EMAIL_EVIDENCE_APPROVE' THEN concat('Auto-approved on email evidence: ', coalesce(c.ai.evidence_reason,''))
    WHEN c.ai.disposition = 'CONTRACT_CHECK_NEEDED'  THEN 'Price increase claims a contractual basis — retrieving and validating the contract clause.'
    ELSE concat('Routed to AP clerk: ', coalesce(c.ai.evidence_reason,'no valid authorisation for the variance'))
  END                                                  AS agent_recommendation,
  concat('ai_classify: disposition=', coalesce(c.ai.disposition,'?'),
         '; confidence=', cast(coalesce(c.ai.confidence,0) AS string),
         '; needs_contract_check=', cast(coalesce(c.ai.needs_contract_check,false) AS string))
                                                       AS agent_rationale
FROM classified c;

-- Distribution by disposition
SELECT disposition, count(*) AS n,
       round(avg(classify_confidence),2) AS avg_conf,
       sum(CASE WHEN needs_contract_check THEN 1 ELSE 0 END) AS need_contract
FROM g_match_exceptions GROUP BY disposition ORDER BY n DESC;
