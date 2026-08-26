USE CATALOG lakemeter_demo_catalog;
USE SCHEMA three_way_match;

-- =============================================================================
-- 04_contract_validation.sql — AUTONOMOUS CONTRACT VALIDATION (Agent Bricks).
--
-- The Agent Bricks SUPERVISOR (endpoint 'mas-fd473d0a-endpoint') uses the Knowledge
-- Assistant over the contracts Volume to retrieve each vendor's price-escalation cap
-- clause. Design notes learned in testing:
--   * The agent endpoint is task type agent/v1/responses — it does NOT support
--     ai_query responseFormat, so it answers in prose and a chat model extracts.
--   * Firing one ai_query per exception row (10-way concurrent) caused intermittent
--     "contract not found" misses. Retrieval is reliable when called once per vendor.
--     So: retrieve + interpret the CLAUSE once per distinct vendor (the agent's hard
--     part), then compute the pass/breach verdict deterministically per invoice
--     (a trivial number comparison the LLM should not re-do per row).
--   * A retry pass re-asks any vendor whose first answer failed to yield a cap.
--
--   WITHIN_CONTRACT -> auto-approve with the cited clause (touchless, audited)
--   BREACH          -> route to AP clerk (the overpayment the tolerance band missed)
-- =============================================================================

-- ── Step 1: one Supervisor call per distinct vendor in the contract-check lane ──
CREATE OR REPLACE TABLE _contract_vendor_raw AS
SELECT
  vendor_id, vendor_name, vendor_tier,
  ai_query(
    'mas-fd473d0a-endpoint',
    concat(
      'Look up the Master Services Agreement for vendor ', vendor_name, ' (vendor id ', vendor_id,
      ') in the finance contracts knowledge base. Quote the exact annual price-increase cap clause ',
      'and state the cap as a percentage number. If you cannot find the contract, say exactly ',
      '"CONTRACT NOT FOUND".'
    )
  ) AS supervisor_answer
FROM (SELECT DISTINCT vendor_id, vendor_name, vendor_tier
      FROM g_match_exceptions WHERE disposition = 'CONTRACT_CHECK_NEEDED');

-- ── Step 1b: retry any vendor whose first answer did not retrieve the contract ──
CREATE OR REPLACE TABLE _contract_vendor AS
SELECT
  vendor_id, vendor_name, vendor_tier,
  CASE
    WHEN upper(supervisor_answer) LIKE '%NOT FOUND%'
      OR upper(supervisor_answer) LIKE '%NOT AVAILABLE%'
      OR upper(supervisor_answer) LIKE '%UNABLE TO%'
    THEN ai_query(
      'mas-fd473d0a-endpoint',
      concat('Search the contracts knowledge base for the file named after vendor ', vendor_id,
             ' (', vendor_name, '). Quote its annual price-increase cap clause and give the cap percentage number.')
    )
    ELSE supervisor_answer
  END AS supervisor_answer
FROM _contract_vendor_raw;

-- ── Step 2: chat model extracts the cap % + clause from the prose (per vendor) ──
CREATE OR REPLACE TABLE _contract_cap AS
SELECT
  vendor_id, vendor_name, vendor_tier, supervisor_answer,
  from_json(
    ai_query(
      'databricks-claude-sonnet-4-5',
      concat(
        'From this contract answer, extract the annual price-increase cap. ',
        'allowed_pct = the cap as a plain number (e.g. 3 for 3%); if none is stated use -1. ',
        'cited_clause = the exact cap clause text quoted (or "unavailable"). ',
        'Answer: ', supervisor_answer
      ),
      responseFormat => 'STRUCT<result:STRUCT<allowed_pct:DOUBLE, cited_clause:STRING>>'
    ),
    'STRUCT<allowed_pct:DOUBLE, cited_clause:STRING>'
  ) AS cap
FROM _contract_vendor;

-- ── Step 3: deterministic verdict per invoice (actual increase vs contracted cap) ──
MERGE INTO g_match_exceptions t
USING (
  SELECT e.invoice_id, e.price_variance_pct,
         c.cap.allowed_pct AS allowed_pct,
         c.cap.cited_clause AS cited_clause,
         (e.price_variance_pct <= c.cap.allowed_pct + 0.001) AS within
  FROM g_match_exceptions e
  JOIN _contract_cap c ON c.vendor_id = e.vendor_id
  WHERE e.disposition = 'CONTRACT_CHECK_NEEDED' AND c.cap.allowed_pct >= 0
) s
ON t.invoice_id = s.invoice_id
WHEN MATCHED THEN UPDATE SET
  t.contract_verdict     = CASE WHEN s.within THEN 'WITHIN_CONTRACT' ELSE 'BREACH' END,
  t.contract_clause      = s.cited_clause,
  t.contract_allowed_pct = s.allowed_pct,
  t.resolution_state     = CASE WHEN s.within THEN 'AUTO_RESOLVED' ELSE 'PENDING_APPROVAL' END,
  t.assigned_approver_role = CASE WHEN s.within THEN NULL ELSE t.default_approver_role END,
  t.agent_recommendation = CASE
      WHEN s.within
        THEN concat('Auto-approved — increase of ', cast(t.price_variance_pct AS string),
                    '% is within the contracted ', cast(s.allowed_pct AS string), '% cap.')
        ELSE concat('CONTRACT BREACH — increase of ', cast(t.price_variance_pct AS string),
                    '% exceeds the contracted ', cast(s.allowed_pct AS string),
                    '% cap. Routed to AP clerk.')
    END,
  t.agent_rationale = concat('contract_check: verdict=',
      CASE WHEN s.within THEN 'WITHIN_CONTRACT' ELSE 'BREACH' END,
      '; allowed=', cast(s.allowed_pct AS string), '%; actual=', cast(t.price_variance_pct AS string), '%');

-- Result of the contract lane
SELECT contract_verdict, count(*) AS n,
       round(avg(price_variance_pct),2) AS avg_actual_pct,
       round(avg(contract_allowed_pct),2) AS avg_allowed_pct
FROM g_match_exceptions
WHERE disposition = 'CONTRACT_CHECK_NEEDED'
GROUP BY contract_verdict ORDER BY contract_verdict;
