USE CATALOG lakemeter_demo_catalog;
USE SCHEMA three_way_match;

-- =============================================================================
-- 00_uc_functions.sql — governed Unity Catalog SQL functions used as tools.
-- (Data-driven tolerance + goods-receipt policy. Defined once, up front.)
-- Note: in the agent-native v3 flow the primary decision engine is AI Classify
-- (step 03) + the Agent Bricks contract check (step 04). These UC functions remain
-- available as governed, auditable policy lookups.
-- =============================================================================

-- ---- get_tolerance: resolve the applicable AP tolerance rule -----------------
-- Resolution precedence: VENDOR (10) < CATEGORY (50) < GLOBAL (100). Lowest wins.
CREATE OR REPLACE FUNCTION get_tolerance(
  p_vendor_id STRING, p_category STRING, p_mismatch_type STRING
)
RETURNS STRUCT<rule_id STRING, tolerance_pct DOUBLE,
               auto_approve_ceiling_inr DOUBLE, required_approver_role STRING>
COMMENT 'Resolve the applicable AP tolerance rule for a vendor/category/mismatch. Most-specific scope wins.'
RETURN (
  SELECT struct(rule_id, tolerance_pct, auto_approve_ceiling_inr, required_approver_role)
  FROM ref_tolerance_rules
  WHERE mismatch_type = p_mismatch_type
    AND ( (scope_type='VENDOR'   AND scope_value = p_vendor_id)
       OR (scope_type='CATEGORY' AND scope_value = p_category)
       OR (scope_type='GLOBAL'   AND scope_value = '*') )
  ORDER BY precedence ASC
  LIMIT 1
);

-- ---- check_gr_policy: goods-receipt policy by vendor tier --------------------
CREATE OR REPLACE FUNCTION check_gr_policy(p_vendor_tier STRING)
RETURNS STRUCT<policy STRING, grace_days INT, required_approver_role STRING>
COMMENT 'Goods-receipt policy for invoices booked before a receipt exists, by vendor tier.'
RETURN (
  SELECT CASE p_vendor_tier
    WHEN 'STRATEGIC' THEN struct('CONFIRM_DELIVERY' AS policy, 5  AS grace_days, 'MANAGER'  AS required_approver_role)
    WHEN 'PREFERRED' THEN struct('CONFIRM_DELIVERY' AS policy, 3  AS grace_days, 'MANAGER'  AS required_approver_role)
    ELSE                  struct('BLOCK_UNTIL_GRN'   AS policy, 0  AS grace_days, 'DIRECTOR' AS required_approver_role)
  END
);
