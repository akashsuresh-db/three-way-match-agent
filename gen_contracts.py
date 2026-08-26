#!/usr/bin/env python3
"""Generate synthetic vendor contract documents and upload to a UC Volume.

Each contract contains a price-escalation clause with a vendor-specific cap so the
Knowledge Assistant / contract check must actually READ the clause — the same %
increase is compliant for one vendor and a breach for another. Written as readable
markdown, one file per vendor, into:
  /Volumes/lakemeter_demo_catalog/three_way_match/contracts/
"""
import io
from databricks.sdk import WorkspaceClient

PROFILE = "fevm-lakemeter-demo"
CATALOG = "lakemeter_demo_catalog"
SCHEMA = "three_way_match"
VOLUME = "contracts"
VOL_PATH = f"/Volumes/{CATALOG}/{SCHEMA}/{VOLUME}"

w = WorkspaceClient(profile=PROFILE)

# Vendor master (id, name, category, tier) — mirrors bronze_vendor_master.
VENDORS = [
    ("V0001", "Acme Components", "IT_HARDWARE", "PREFERRED"),
    ("V0002", "Globex Supplies", "MRO", "STANDARD"),
    ("V0003", "Initech Systems", "LOGISTICS", "STRATEGIC"),
    ("V0004", "Umbrella Materials", "PACKAGING", "PREFERRED"),
    ("V0005", "Stark Industrial", "RAW_MATERIALS", "STANDARD"),
    ("V0006", "Wayne Logistics", "IT_HARDWARE", "STRATEGIC"),
    ("V0007", "Wonka Packaging", "SERVICES", "PREFERRED"),
    ("V0008", "Cyberdyne Parts", "MRO", "STANDARD"),
    ("V0009", "Soylent Foods", "RAW_MATERIALS", "STRATEGIC"),
    ("V0010", "Hooli Cloud", "SERVICES", "PREFERRED"),
    ("V0011", "Pied Piper Data", "SERVICES", "STANDARD"),
    ("V0012", "Vandelay Imports", "PACKAGING", "STRATEGIC"),
    ("V0013", "Massive Dynamic", "IT_HARDWARE", "PREFERRED"),
    ("V0014", "Gekko Capital Goods", "MRO", "STANDARD"),
    ("V0015", "Nakatomi Trading", "LOGISTICS", "STRATEGIC"),
]

# Price-escalation cap by tier. STANDARD vendors get the tight 3% cap — this is the
# cap the contract-basis invoices (+2.5% pass / +4.0% breach) are tested against.
# (Cyberdyne Parts V0008 = STANDARD -> 3% cap, and it is the contract-basis vendor.)
CAP_BY_TIER = {"STRATEGIC": 5, "PREFERRED": 4, "STANDARD": 3}


def contract_md(vid, name, category, tier):
    cap = CAP_BY_TIER[tier]
    tag = f"{name} ({vid})"
    # Vendor identity is saturated into every section/chunk so semantic retrieval for
    # a given vendor unambiguously returns THIS document (the 15 contracts otherwise
    # share a template and collide in vector search).
    return f"""# Master Services Agreement for {tag}

> This contract belongs to vendor {tag}. Vendor ID: {vid}. Vendor name: {name}.
> Keywords: {vid} {name} {name} contract MSA pricing cap escalation.

**Vendor ID:** {vid}
**Vendor name:** {name}
**Category:** {category}
**Relationship tier:** {tier}
**Effective date:** 2025-04-01
**Currency:** INR

## 1. Scope — {tag}
This Master Services Agreement ("Agreement") for vendor {tag} governs the supply of
{category.replace('_',' ').lower()} goods and services by {name} (vendor id {vid}, the "Supplier")
to the Buyer. All purchase orders issued to {name} ({vid}) under this Agreement are subject to the
terms below.

## 2. Pricing and Annual Escalation — {tag}
2.1 Unit prices for {name} ({vid}) are as set out in each Purchase Order (PO).
2.2 Vendor {name} ({vid}) may increase unit pricing **once per contract year**, in line with the
    Consumer Price Index (CPI), **capped at {cap}% per annum for {name} ({vid})**. Any increase
    above {cap}% requires a signed contract amendment countersigned by the Buyer's procurement lead
    before it may be invoiced.
2.3 Price increases invoiced by {name} ({vid}) without a corresponding amendment, or exceeding the
    {cap}% annual cap, are considered a pricing breach and shall be rejected or short-paid to the
    contracted rate. The annual price-increase cap for {name} ({vid}) is {cap}%.

## 3. Freight and Expedited Shipping — {tag}
3.1 Standard freight is included in {name} ({vid}) unit pricing (DDP).
3.2 Expedited or air-freight charges are payable **only** where pre-approved in writing by the
    Buyer's procurement or operations team for a specific shipment.

## 4. Quantity and Delivery — {tag}
4.1 {name} ({vid}) shall deliver the quantities stated on the PO.
4.2 Over-delivery is permitted only where requested or approved in writing by the Buyer.

## 5. Invoicing — {tag}
5.1 Each {name} ({vid}) invoice must reference a valid PO number.
5.2 Invoices are subject to three-way match (PO, goods receipt, invoice) prior to payment.

## 6. Governing terms — {tag}
This Agreement for {name} ({vid}) supersedes prior pricing correspondence. In case of conflict
between an invoice and this Agreement, the Agreement prevails. End of MSA for {name} ({vid}).
"""


def main():
    # Create the volume (idempotent).
    try:
        w.volumes.create(catalog_name=CATALOG, schema_name=SCHEMA, name=VOLUME,
                         volume_type="MANAGED")
        print(f"created volume {VOL_PATH}")
    except Exception as e:
        print(f"volume exists or: {e}")

    for vid, name, category, tier in VENDORS:
        md = contract_md(vid, name, category, tier)
        fname = f"{vid}_{name.replace(' ', '_')}_MSA.md"
        dest = f"{VOL_PATH}/{fname}"
        w.files.upload(dest, io.BytesIO(md.encode("utf-8")), overwrite=True)
        print(f"uploaded {dest}  (cap {CAP_BY_TIER[tier]}%)")

    print("DONE")


if __name__ == "__main__":
    main()
