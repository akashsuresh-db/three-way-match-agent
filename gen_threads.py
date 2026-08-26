#!/usr/bin/env python3
"""Author unique, messy, real-world unstructured artifacts per showcase invoice.

For 15 hand-picked exceptions (spanning every disposition) we call ai_query to WRITE
a realistic multi-message email thread + a PO comment + an invoice memo, grounded on
that invoice's actual facts and a distinct scenario brief. The briefs deliberately
include follow-ups, quoted replies, and buried reasons — and a few where a LATER
message flips the conclusion, so the classifier must read the whole chain, not the
first line. Output is stored in lakemeter_demo_catalog.three_way_match.showcase_threads.
"""
import json
from databricks.sdk import WorkspaceClient
from databricks.sdk.service.sql import StatementState

PROFILE, WID = "fevm-lakemeter-demo", "59003c369444b958"
CAT, SCH = "lakemeter_demo_catalog", "three_way_match"
w = WorkspaceClient(profile=PROFILE)


def run(sql):
    r = w.statement_execution.execute_statement(warehouse_id=WID, catalog=CAT, schema=SCH,
                                                 statement=sql, wait_timeout="50s")
    while r.status.state in (StatementState.PENDING, StatementState.RUNNING):
        r = w.statement_execution.get_statement(r.statement_id)
    if r.status.state != StatementState.SUCCEEDED:
        raise RuntimeError(r.status.error.message if r.status.error else str(r.status.state))
    return r


# invoice_id -> scenario brief. `intent` documents the expected disposition (for our
# own verification), NOT fed as an answer; the thread is written to imply it naturally.
BRIEFS = {
    # ── documented approval somewhere in the chain -> EMAIL_EVIDENCE_APPROVE ──
    "INV000012": dict(vendor="Massive Dynamic", intent="approved-premium",
        situation="Production line was down; this replacement server hardware was air-freighted overnight so the line could restart. The unit price is ~18% above the PO because of the emergency premium + air freight.",
        twist="AP first pushes back on the premium; a follow-up reply from the Plant Director explicitly approves the extra cost and references the incident ticket. The approval is only in the LAST message."),
    "INV000042": dict(vendor="Massive Dynamic", intent="approved-premium",
        situation="Rush order of demo units for a big customer POC; ~18% premium for same-week delivery.",
        twist="Thread has a forwarded/quoted approval from the Sales VP buried under two logistics replies about tracking numbers."),
    "INV000006": dict(vendor="Wonka Packaging", intent="approved-extra-scope",
        situation="Consulting engagement; supplier billed ~14% more units (extra days) to hit a go-live date.",
        twist="Opening message looks like unapproved scope creep; a later reply attaches an SOW change-note approving the extra days — the follow-up flips it from 'dispute' to 'approved'."),
    "INV000016": dict(vendor="Globex Supplies", intent="approved-extra-qty",
        situation="Buyer asked the supplier to ship ~15% extra spare parts as safety stock ahead of a maintenance shutdown.",
        twist="Casual, short thread; the approval is informal ('yep go ahead - Ravi') rather than a formal sign-off."),
    "INV000206": dict(vendor="Vandelay Imports", intent="approved-extra-qty",
        situation="Large packaging order (~₹3L); ~15% extra units for a seasonal promo, pre-approved by the Category Manager.",
        twist="Long thread with 4-5 messages incl. a procurement query about the promo budget code, resolved before approval."),
    # ── claims a contractual basis -> CONTRACT_CHECK_NEEDED (Supervisor verifies) ──
    "INV000052": dict(vendor="Cyberdyne Parts", intent="contract-cpi",
        situation="Supplier applied a +4% annual price increase and says it's the CPI-linked uplift under the master agreement.",
        twist="Supplier is confident and cites 'clause 2.2'; AP is unsure of the exact cap — needs the contract checked."),
    "INV000112": dict(vendor="Cyberdyne Parts", intent="contract-index",
        situation="Supplier applied +4% and attributes it to a raw-material / steel index pass-through they say the contract allows.",
        twist="Different justification from the CPI one; supplier's language is vague about which clause — must be verified against the actual agreement."),
    "INV000202": dict(vendor="Cyberdyne Parts", intent="contract-within",
        situation="Supplier applied a modest +2.5% annual escalation, says it's per the agreed CPI cap.",
        twist="Polite, brief; supplier proactively says 'well within our 3% cap' — still must be verified, and it checks out."),
    "INV000232": dict(vendor="Cyberdyne Parts", intent="contract-amendment-missing",
        situation="Supplier applied +4% and references a 'signed amendment from last quarter' authorising a higher cap.",
        twist="AP cannot find the amendment on file; thread ends unresolved — the contract check must confirm whether any such higher cap exists (it does not)."),
    # ── no valid evidence / structural -> CLERK_REVIEW ──
    "INV000032": dict(vendor="Initech Systems", intent="no-authorisation",
        situation="Supplier applied ~18% higher rate this quarter with no PO change.",
        twist="TWIN of the approved case: supplier CLAIMS 'as agreed with your team' but when AP asks who approved, a follow-up shows procurement replying 'we have no record of approving this'. Chain ends with NO authorisation."),
    "INV000003": dict(vendor="Umbrella Materials", intent="no-po-maverick",
        situation="Invoice arrived with no PO referenced (maverick spend).",
        twist="Requestor emails 'just pay it, we needed it urgently'; no PO was ever raised — unauthorised process breach, needs a person."),
    "INV000005": dict(vendor="Wayne Logistics", intent="qty-unexplained",
        situation="Invoiced quantity is far higher (~69%) than what was received/ordered.",
        twist="Invoice memo claims it 'consolidates three POs' but only one PO is referenced and the other two can't be located — genuinely needs investigation."),
    "INV000010": dict(vendor="Pied Piper Data", intent="gr-missing-services",
        situation="Services invoice with no goods receipt / no proof of delivery posted.",
        twist="Supplier says 'work completed'; the internal owner hasn't confirmed sign-off in the thread — cannot pay without confirmation."),
    "INV000020": dict(vendor="Wayne Logistics", intent="gr-missing-goods",
        situation="Hardware invoiced (~₹80k) but not yet received; no GRN.",
        twist="Thread shows the shipment is delayed in transit; supplier invoiced early — hold until goods are receipted."),
    # ── duplicate resubmission -> CLERK_REVIEW (hard hold) ──
    "INV000301": dict(vendor="Cyberdyne Parts", intent="duplicate",
        situation="Supplier re-sent an invoice chasing payment.",
        twist="Supplier says 'resending as we've had no payment'; it is in fact already booked under the original invoice number — a duplicate, must be held before the payment run."),
}


def gen_prompt(inv, facts, brief):
    return (
        "You write realistic accounts-payable correspondence. Produce the messy unstructured "
        "artifacts that would accompany ONE real invoice exception. Make it organic: natural human "
        "writing, varied length and tone, real names/roles, quoted replies, follow-ups, tangents, "
        "signatures. Do NOT state a disposition or use words like 'approve/breach/clerk'. Just write "
        "what the people actually wrote.\n\n"
        f"Invoice: {inv} from {facts['vendor_name']} ({facts['vendor_id']}, {facts['vendor_category']}). "
        f"Amount INR {facts['amt']}. Price variance {facts['px']}%, quantity variance {facts['qx']}%, "
        f"match status {facts['match_status']}.\n"
        f"Scenario: {brief['situation']}\n"
        f"Important detail to weave in: {brief['twist']}\n\n"
        "Return three fields:\n"
        "email_thread: a multi-message email chain (2-5 messages, newest or oldest first, with "
        "From/To/Subject/date-ish headers, quoted '>' history, signatures) — the real back-and-forth.\n"
        "po_comment: a short free-text note a buyer left on the purchase order (1-2 sentences), or "
        "empty string if none would exist.\n"
        "invoice_memo: a short note the supplier put on the invoice itself (1 sentence), or empty string."
    )


def main():
    ids = "','".join(BRIEFS)
    rows = run(f"""SELECT invoice_id, vendor_id, vendor_name, vendor_category,
                          round(invoice_amount,0) amt, round(price_variance_pct,1) px,
                          round(qty_variance_pct,1) qx, match_status
                   FROM g_match_exceptions WHERE invoice_id IN ('{ids}')""")
    cols = [c.name for c in rows.manifest.schema.columns]
    facts_by = {r[0]: dict(zip(cols, r)) for r in rows.result.data_array}

    # build one big VALUES insert after generating each artifact
    run("""CREATE OR REPLACE TABLE showcase_threads (
             invoice_id STRING, email_thread STRING, po_comment STRING, invoice_memo STRING)""")

    for inv, brief in BRIEFS.items():
        f = facts_by[inv]
        prompt = gen_prompt(inv, f, brief).replace("'", "''")
        r = run(f"""SELECT from_json(ai_query('databricks-claude-sonnet-4-5', '{prompt}',
                      responseFormat => 'STRUCT<result:STRUCT<email_thread:STRING, po_comment:STRING, invoice_memo:STRING>>'),
                      'STRUCT<email_thread:STRING, po_comment:STRING, invoice_memo:STRING>') AS a""")
        # the struct comes back as a JSON string in data_array
        val = r.result.data_array[0][0]
        art = json.loads(val)
        et = (art.get("email_thread") or "").replace("'", "''")
        pc = (art.get("po_comment") or "").replace("'", "''")
        im = (art.get("invoice_memo") or "").replace("'", "''")
        run(f"""INSERT INTO showcase_threads VALUES
                ('{inv}', '{et}', '{pc}', '{im}')""")
        print(f"{inv}: thread {len(et)} chars | po_comment {len(pc)} | memo {len(im)}")

    n = run("SELECT count(*) FROM showcase_threads").result.data_array[0][0]
    print(f"DONE — {n} showcase threads")


if __name__ == "__main__":
    main()
