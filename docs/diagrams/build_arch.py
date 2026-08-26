import sys
SK = "/Users/akash.s/.vibe/marketplace/plugins/fe-specialized-agents/skills/drawio-diagram/scripts"
sys.path.insert(0, SK)
from generate_drawio import DrawioBuilder, load_icons

icons = load_icons()
b = DrawioBuilder(width=1780, height=900, icons_cache=icons)

b.add_title(40, 12, 1700, "P2P Intelligence — Invoice Exception Resolution on Databricks",
            subtitle="Deterministic 3-way match → AI classification of the correspondence → autonomous contract validation → touchless clearance / clerk queue")

b.add_banner(40, 60, 1700, "DATA FLOW  →")

Y = 100
# ── Column 1: Sources ──
c_src = b.add_container(40, Y, 200, 430, "Source systems", "sources")
s_erp = b.add_node(15, 45, 170, 74, "ERP: Invoices / PO / GRN", "purple", icon_name="data_pipelines", parent=c_src)
s_mail = b.add_node(15, 140, 170, 74, "Vendor email threads", "purple", icon_name="human", parent=c_src)
s_ctr = b.add_node(15, 235, 170, 74, "Vendor contracts (MSA PDFs)", "purple", icon_name="share", parent=c_src)
s_po = b.add_node(15, 330, 170, 74, "PO comments / invoice memos", "purple", icon_name="notebook", parent=c_src)

# ── Column 2: Ingest + Storage (Unity Catalog) ──
c_ing = b.add_container(280, Y, 210, 430, "Ingest & store — Unity Catalog", "ingestion")
i_bronze = b.add_node(15, 45, 180, 74, "Bronze tables (Delta)", "bronze", icon_name="unstructured_bronze", parent=c_ing)
i_vol = b.add_node(15, 140, 180, 74, "Contracts UC Volume", "yellow", icon_name="cloud_storage", parent=c_ing)
i_thread = b.add_node(15, 235, 180, 74, "Email threads table (Delta)", "silver", icon_name="delta_table", parent=c_ing)
i_lake = b.add_node(15, 330, 180, 74, "Lakeflow ingest job", "compute_green", icon_name="data_pipelines", parent=c_ing)

# ── Column 3: Deterministic 3-way match ──
c_match = b.add_container(530, Y, 210, 430, "Step 1 · 3-way match (SQL)", "compute")
m_match = b.add_node(15, 45, 180, 84, "Line-level match: Invoice ↔ PO ↔ GRN", "compute_green", icon_name="data_quality_2", parent=c_match)
m_finding = b.add_node(15, 150, 180, 74, "Deterministic finding + variance deltas", "compute_green", icon_name="spark", parent=c_match)
m_exc = b.add_node(15, 245, 180, 84, "g_match_exceptions (Delta gold)", "gold", icon_name="delta_lake", parent=c_match)
m_dup = b.add_node(15, 340, 180, 66, "Duplicate gate (SQL blocking)", "red", icon_name="data_quality_3", parent=c_match)

# ── Column 4: AI classify ──
c_ai = b.add_container(780, Y, 210, 430, "Step 2 · Classify (AI Functions)", "aiml")
a_q = b.add_node(15, 45, 180, 90, "ai_query — reads full email thread + PO/memo", "orange", icon_name="ai", parent=c_ai)
a_fm = b.add_node(15, 155, 180, 74, "Foundation Model API (Claude)", "orange", icon_name="machine_learning", parent=c_ai)
a_disp = b.add_node(15, 250, 180, 84, "Disposition + business reason (structured output)", "orange", icon_name="predict", parent=c_ai)

# ── Column 5: Contract validation (Agent Bricks) ──
c_agent = b.add_container(1030, Y, 220, 430, "Step 3 · Validate contract (Agent)", "aiml")
g_sup = b.add_node(15, 45, 190, 84, "Supervisor agent (Model Serving)", "teal", icon_name="endpoint", parent=c_agent)
g_ka = b.add_node(15, 150, 190, 74, "Knowledge Assistant (RAG)", "teal", icon_name="mlflow", parent=c_agent)
g_vs = b.add_node(15, 245, 190, 74, "Vector Search — contract clauses", "teal", icon_name="catalog_store", parent=c_agent)
g_verd = b.add_node(15, 340, 190, 64, "Verdict: within-cap / breach + cited clause", "teal", icon_name="production_ready", parent=c_agent)

# ── Column 6: Decision / state ──
c_dec = b.add_container(1290, Y, 190, 430, "Decision & state", "medallion")
d_uc = b.add_node(15, 45, 160, 74, "UC functions: tolerance / GR policy", "gold", icon_name="unity_catalog", parent=c_dec)
d_state = b.add_node(15, 140, 160, 84, "Resolution state machine (Delta view)", "gold", icon_name="workflows_2", parent=c_dec)
d_audit = b.add_node(15, 245, 160, 74, "Audit log + approvals (maker-checker)", "silver", icon_name="compliance", parent=c_dec)
d_pay = b.add_node(15, 330, 160, 74, "Cleared for payment", "green", icon_name="output", parent=c_dec)

# ── Column 7: Consumption ──
c_con = b.add_container(1520, Y, 220, 430, "Business users", "consumption")
u_app = b.add_node(15, 45, 190, 84, "Databricks App (FastAPI + React)", "blue", icon_name="apps_services", parent=c_con)
u_clerk = b.add_node(15, 150, 190, 64, "AP clerk — exception queue", "blue", icon_name="3_people", parent=c_con)
u_chat = b.add_node(15, 230, 190, 84, "Ask assistant (streaming) via Supervisor", "blue", icon_name="ai", parent=c_con)
u_genie = b.add_node(15, 335, 190, 64, "Genie space — ad-hoc Q&A", "blue", icon_name="data_science_notebook", parent=c_con)

# ── Governance banner ──
c_gov = b.add_container(280, Y + 450, 1460, 96, "Unity Catalog — governance, lineage & security across every table, volume, function, model & agent", "governance", dashed=True)
b.add_node(20, 40, 168, 44, "Unity Catalog", "gov", parent=c_gov, shape="pill")
b.add_node(210, 40, 168, 44, "Lineage", "gov", parent=c_gov, shape="pill")
b.add_node(400, 40, 168, 44, "Access control", "gov", parent=c_gov, shape="pill")
b.add_node(590, 40, 178, 44, "Audit / SOX trail", "gov", parent=c_gov, shape="pill")
b.add_node(790, 40, 178, 44, "Serverless compute", "gov", parent=c_gov, shape="pill")

# ── Edges (horizontal L→R) ──
def e(s, t, lbl=""):
    b.add_edge(s, t, lbl, exit_x=1, exit_y=0.5, entry_x=0, entry_y=0.5, stroke_width=2, font_style=1)

e(s_erp, i_bronze)
e(s_ctr, i_vol)
e(s_mail, i_thread)
e(i_bronze, m_match)
e(i_lake, m_match)
e(m_exc, a_q)
e(a_disp, g_sup, "if contractual")
e(a_disp, d_state, "email-approved / clerk")
e(g_verd, d_state)
e(g_vs, g_ka)  # KA uses vector search
b.add_edge(g_ka, g_sup, "", exit_x=0.5, exit_y=0, entry_x=0.5, entry_y=1, stroke_width=1.5)
e(d_state, u_app)
e(d_pay, u_app)
# app chat back to supervisor (dashed, secondary)
b.add_edge(u_chat, g_sup, "", stroke_width=1.2, dashed=True, exit_x=0, exit_y=0.5, entry_x=1, entry_y=0.5)

b.add_flow_description(40, Y + 560, 1700, [
    {"num": 1, "text": "ERP invoices/PO/GRN, vendor email threads, PO comments and contract PDFs land in Unity Catalog (Delta tables + a contracts Volume) via Lakeflow."},
    {"num": 2, "text": "A deterministic SQL 3-way match finds which leg broke (price / quantity / missing GR / no PO) and writes exceptions with exact variance deltas; a set-based gate flags duplicate resubmissions."},
    {"num": 3, "text": "ai_query (Foundation Model API) reads the full correspondence chain and assigns a business disposition + specific reason — the signal a fixed-tolerance rule cannot see."},
    {"num": 4, "text": "For increases claiming a contractual basis, the Supervisor agent queries a Knowledge Assistant (Vector Search over the contracts) to retrieve the cap clause and return within-cap / breach with a citation."},
    {"num": 5, "text": "Governed UC functions + a Delta state machine record every decision (maker-checker audit); touchless approvals clear for payment, genuine exceptions route to the AP clerk in the Databricks App, with a streaming Ask assistant and Genie for ad-hoc questions."},
], title="How it works")

b.print_validation()
b.save("/Users/akash.s/three-way-match-agent/docs/diagrams/p2p_architecture.drawio")
print("saved")
