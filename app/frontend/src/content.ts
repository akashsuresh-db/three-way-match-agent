// Capability card content for the expandable pipeline-flow cards.
export type Capability = {
  n: string
  t: string
  short: string          // one-liner shown on the card face
  capability: string     // which Databricks capability solves this
  detail: string         // crisp explanation shown on expand
  bullets?: string[]     // optional extra points
  shot: string           // screenshot filename under /screenshots
}

export const CAPABILITIES: Capability[] = [
  {
    n: '01',
    t: 'Match fails',
    short: 'Invoice vs PO vs Goods Receipt',
    capability: 'Lakeflow / Delta on Unity Catalog',
    detail:
      'Invoices are matched to their PO and Goods Receipt at line level; price, quantity and ' +
      'receipt deltas are computed deterministically in SQL. This cheap first pass only flags ' +
      'that an invoice failed — it cannot tell why, or whether the failure is actually authorised.',
    shot: 'match.png',
  },
  {
    n: '02',
    t: 'Classify the exception',
    short: 'Uses the email that arrived with the invoice',
    capability: 'Databricks AI Functions — ai_query (structured output)',
    detail:
      'Each failed invoice carries the email that came with it. The step reads that email plus the ' +
      'computed deltas and assigns a disposition, with the supporting reason extracted and stored. ' +
      'Where the numbers are identical but the authorisation differs, the outcome differs — the ' +
      'basis for each is recorded against the invoice.',
    bullets: [
      'TOUCHLESS_AUTO_APPROVE — within tolerance, no ambiguity',
      'EMAIL_EVIDENCE_APPROVE — documented approval in the email; reason stored',
      'CONTRACT_CHECK_NEEDED — increase cites a contractual basis; sent for validation',
      'CLERK_REVIEW — no supporting evidence; routed to a person',
    ],
    shot: 'ai_classify.png',
  },
  {
    n: '03',
    t: 'Validate against the contract',
    short: 'Checks the increase against the vendor agreement',
    capability: 'Agent Bricks Supervisor + Knowledge Assistant',
    detail:
      'Invoices flagged CONTRACT_CHECK_NEEDED are checked against the vendor’s Master Services ' +
      'Agreement. A Knowledge Assistant holding every contract returns the governing price-escalation ' +
      'clause; the invoiced increase is compared to the contracted cap. Within cap clears with the ' +
      'clause cited; over cap is held. This catches increases that sit within a flat AP tolerance ' +
      'band but exceed the specific vendor’s contracted cap.',
    bullets: [
      'Retrieval is per-vendor, against that vendor’s agreement',
      'Knowledge Assistant indexes the contracts stored in Unity Catalog',
      'Within cap → cleared, with the cited clause on record',
      'Over cap → held for the AP clerk, with the clause and the gap',
    ],
    shot: 'contract_agent.png',
  },
  {
    n: '04',
    t: 'Cleared for payment',
    short: 'Resolved without a person, with evidence',
    capability: 'Delta state machine + audit log',
    detail:
      'Invoices resolved without a person: clean matches, email-authorised approvals, and ' +
      'contract-validated approvals. Each carries a stored reason or a cited clause, so any ' +
      'clearance can be traced back to its basis.',
    shot: 'decision.png',
  },
  {
    n: '05',
    t: 'Left for the AP clerk',
    short: 'Unauthorised, unmatched, or breached only',
    capability: 'Maker-checker on Delta',
    detail:
      'What remains for a person: unauthorised increases, contract breaches, missing PO or receipt, ' +
      'and duplicate holds. Each arrives with the email, the recorded reasoning, and — for contract ' +
      'cases — the cited clause already attached.',
    shot: 'approval.png',
  },
]

// What Approve / Reject means per disposition (4 lanes).
export type ActionExplainer = { type: string; label: string; approve: string; reject: string }

export const ACTION_EXPLAINERS: ActionExplainer[] = [
  {
    type: 'EMAIL_EVIDENCE_APPROVE', label: 'Email-evidence approve',
    approve: 'The agent already auto-approved on the buyer/supplier email authorisation; the extracted reason is stored for audit. A clerk only reviews if they want to spot-check the evidence.',
    reject: 'If the email is not genuine authorisation, the clerk overturns it — the invoice is held and returned to the vendor/buyer for a corrected invoice or proper approval.',
  },
  {
    type: 'CONTRACT_CHECK_NEEDED', label: 'Contract validation',
    approve: 'The Knowledge Assistant confirmed the increase is within the contracted cap; the agent auto-approves with the cited clause. Clerk sign-off is optional.',
    reject: 'The retrieved clause shows a breach (increase exceeds the contracted cap) — the invoice is short-paid to the contracted rate or returned to the vendor.',
  },
  {
    type: 'CLERK_REVIEW', label: 'Clerk review',
    approve: 'Clerk confirms the spend is valid (e.g. links a retrospective PO or accepts an explained variance); the invoice then clears for payment.',
    reject: 'Unauthorised increase, missing PO/receipt, or no evidence — the invoice is held and sent back for correction.',
  },
  {
    type: 'TOUCHLESS_AUTO_APPROVE', label: 'Touchless',
    approve: 'Clean or within-tolerance — auto-approved with no human action needed.',
    reject: 'Rarely used; a clerk can still pull one back if something looks off.',
  },
]
