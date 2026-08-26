import { useEffect, useRef, useState } from 'react'
import { CAPABILITIES, ACTION_EXPLAINERS } from './content'

const DISPOSITIONS = ['TOUCHLESS_AUTO_APPROVE', 'EMAIL_EVIDENCE_APPROVE', 'CONTRACT_CHECK_NEEDED', 'CLERK_REVIEW']
const fmt = (n: number) => '₹' + Number(n).toLocaleString('en-IN', { maximumFractionDigits: 0 })
// compact INR for headline figures: crore / lakh
const fmtCr = (n: number) => {
  const v = Number(n)
  if (v >= 1e7) return '₹' + (v / 1e7).toFixed(2) + ' Cr'
  if (v >= 1e5) return '₹' + (v / 1e5).toFixed(2) + ' L'
  return '₹' + v.toLocaleString('en-IN', { maximumFractionDigits: 0 })
}
type Row = Record<string, any>

function App() {
  const [metrics, setMetrics] = useState<any>(null)
  const [rows, setRows] = useState<Row[]>([])
  const [dispF, setDispF] = useState('all')
  const [scope, setScope] = useState('showcase')
  const [sel, setSel] = useState<string | null>(null)
  const [openCap, setOpenCap] = useState<string | null>(null)
  const [hero, setHero] = useState<any>(null)

  const loadMetrics = () => fetch('/api/metrics').then(r => r.json()).then(setMetrics)
  const loadRows = () => {
    const q = new URLSearchParams({ disposition: dispF, scope })
    fetch('/api/exceptions?' + q).then(r => r.json()).then(d => setRows(d.rows))
  }
  useEffect(() => { loadMetrics(); fetch('/api/hero').then(r => r.json()).then(setHero) }, [])
  useEffect(() => { loadRows() }, [dispF, scope])
  const refresh = () => { loadMetrics(); loadRows() }

  return (
    <div className="app">
      <div className="header">
        <div>
          <h1>P2P Intelligence</h1>
          <div className="sub">Invoice exception handling — outcomes for the period, each figure traceable to the underlying invoices.</div>
        </div>
      </div>

      {/* clickable capability flow */}
      <div className="flow">
        {CAPABILITIES.map(c => (
          <div className={'step' + (openCap === c.n ? ' open' : '')} key={c.n} onClick={() => setOpenCap(openCap === c.n ? null : c.n)}>
            <div className="n">{c.n}</div>
            <div className="t">{c.t}</div>
            <div className="d">{c.short}</div>
            <div className="expand-hint">{openCap === c.n ? '−' : '+'}</div>
          </div>
        ))}
      </div>

      {openCap && (() => {
        const c = CAPABILITIES.find(x => x.n === openCap)!
        return (
          <div className="cap-panel">
            <div className="cap-body">
              <div className="cap-tag">{c.capability}</div>
              <h3>{c.t}</h3>
              <p>{c.detail}</p>
              {c.bullets && <ul className="cap-bullets">{c.bullets.map((b, i) => <li key={i}>{b}</li>)}</ul>}
            </div>
            <div className="cap-shot">
              <img src={'/screenshots/' + c.shot} alt={c.t}
                onError={e => { (e.target as HTMLImageElement).style.display = 'none'; (e.target as HTMLImageElement).parentElement!.classList.add('noimg') }} />
              <div className="shot-ph">Databricks UI — {c.shot}</div>
            </div>
          </div>
        )
      })()}

      {metrics && (
        <div className="kpis kpis-4">
          <div className="kpi green">
            <div className="label">Cash protected before payment</div>
            <div className="value">{fmtCr(metrics.money_protected)}</div>
            <div className="foot">{metrics.dup_blocked_n} duplicates ({fmtCr(metrics.dup_blocked_inr)}) + {metrics.breach_held_n} contract breaches ({fmtCr(metrics.breach_held_inr)})</div>
          </div>
          <div className="kpi">
            <div className="label">Cleared without a person</div>
            <div className="value">{metrics.cleared_no_human}<span className="of">/ {metrics.total_invoices}</span></div>
            <div className="foot">{metrics.reviews_removed} were exceptions a tolerance rule would have queued for review</div>
          </div>
          <div className="kpi amber">
            <div className="label">Left for the AP clerk</div>
            <div className="value">{metrics.clerk_queue}<span className="of">/ {metrics.total_invoices}</span></div>
            <div className="foot">only unauthorised, unmatched, or breached invoices</div>
          </div>
          <div className="kpi">
            <div className="label">Auto-clearance audit coverage</div>
            <div className="value">{metrics.audit_coverage_pct}%</div>
            <div className="foot">each auto-cleared invoice carries a stored reason or cited clause</div>
          </div>
        </div>
      )}

      {/* Evidence: the specific invoices behind two claims a rules engine would get wrong.
          No narrative — just the record, filterable to verify. */}
      {hero && hero.email_split?.length === 2 && hero.contract_split?.length >= 2 && (() => {
        const e = hero.email_split, c = hero.contract_split
        const eApprove = e.find((x: any) => x.disposition === 'EMAIL_EVIDENCE_APPROVE') || e[0]
        const eClerk = e.find((x: any) => x.disposition === 'CLERK_REVIEW') || e[1]
        const cOk = c.find((x: any) => x.contract_verdict === 'WITHIN_CONTRACT') || c[0]
        const cBreach = c.find((x: any) => x.contract_verdict === 'BREACH') || c[1]
        return (
          <div className="heroband">
            <div className="hero-h">Two decisions a fixed-tolerance rule would get wrong — the invoices, on the record</div>
            <div className="hero-cards">
              <div className="hero-card">
                <div className="hero-t">Identical {eApprove.price_pct}% price rise, same rule outcome — resolved differently on the documented authorisation.</div>
                <div className="hero-pair">
                  <div className="hero-side ok" onClick={() => setSel(eApprove.invoice_number.replace('-A',''))} style={{ cursor: 'pointer' }}>
                    <span className="mono">{eApprove.invoice_number}</span> · {eApprove.vendor_name}
                    <div className="hero-note">Buyer email: “{(eApprove.email_note || '').slice(0, 68)}…”</div>
                    <div className="hero-verdict ok">Cleared — approval on file <span>({eApprove.price_pct}%)</span></div>
                  </div>
                  <div className="hero-side bad" onClick={() => setSel(eClerk.invoice_number.replace('-A',''))} style={{ cursor: 'pointer' }}>
                    <span className="mono">{eClerk.invoice_number}</span> · {eClerk.vendor_name}
                    <div className="hero-note">Supplier email: “{(eClerk.email_note || '').slice(0, 68)}…”</div>
                    <div className="hero-verdict bad">Held for review — no authorisation <span>({eClerk.price_pct}%)</span></div>
                  </div>
                </div>
              </div>
              <div className="hero-card">
                <div className="hero-t">Both increases fall under a flat 5% tolerance — one is a contract breach, verified against the vendor’s own agreement.</div>
                <div className="hero-pair">
                  <div className="hero-side ok" onClick={() => setSel(cOk.invoice_number)} style={{ cursor: 'pointer' }}>
                    <span className="mono">{cOk.invoice_number}</span> · {cOk.vendor_name}
                    <div className="hero-verdict ok">Cleared — within cap <span>({cOk.price_pct}% ≤ {cOk.contract_allowed_pct}%)</span></div>
                  </div>
                  <div className="hero-side bad" onClick={() => setSel(cBreach.invoice_number)} style={{ cursor: 'pointer' }}>
                    <span className="mono">{cBreach.invoice_number}</span> · {cBreach.vendor_name}
                    <div className="hero-verdict bad">Held — over cap <span>({cBreach.price_pct}% &gt; {cBreach.contract_allowed_pct}%)</span></div>
                  </div>
                </div>
                <div className="hero-foot">A flat 5% tolerance clears both; the vendor’s contract caps this one at {cBreach.contract_allowed_pct}%. Click a row to see the cited clause.</div>
              </div>
            </div>
          </div>
        )
      })()}

      <div className="filters">
        <button className={'chip' + (dispF === 'all' ? ' active' : '')} onClick={() => setDispF('all')}>All dispositions</button>
        {DISPOSITIONS.map(t => (
          <button key={t} className={'chip' + (dispF === t ? ' active' : '')} onClick={() => setDispF(t)}>{t.replace(/_/g, ' ')}</button>
        ))}
        <div className="spacer" />
        <button className={'chip' + (scope === 'showcase' ? ' active' : '')} onClick={() => setScope('showcase')}>Worked examples</button>
        <button className={'chip' + (scope === 'all' ? ' active' : '')} onClick={() => setScope('all')}>Full period</button>
      </div>

      <div className="table-cap">Click any row to read the full correspondence the AI worked from and the reason it extracted.</div>
      <table className="table">
        <thead>
          <tr><th>Invoice</th><th>Vendor</th><th>Disposition</th><th>Reason the AI found</th><th className="right">Amount</th><th>Outcome</th></tr>
        </thead>
        <tbody>
          {rows.map(r => (
            <tr key={r.invoice_id} onClick={() => setSel(r.invoice_id)}>
              <td className="mono">{r.invoice_number}{r.is_showcase ? <span className="doc-badge" title="Has full email thread + PO comment + invoice memo">✉ thread</span> : null}</td>
              <td>{r.vendor_name}<div style={{ color: 'var(--muted)', fontSize: 11 }}>{r.vendor_category}</div></td>
              <td><span className={'pill ' + r.disposition}>{(r.disposition || '').replace(/_/g, ' ')}</span></td>
              <td style={{ maxWidth: 380, fontSize: 12.5 }}>{r.business_reason || <span style={{ color: 'var(--muted)' }}>{r.agent_recommendation}</span>}</td>
              <td className="right mono">{fmt(r.invoice_amount)}</td>
              <td><span className={'state ' + r.effective_state}>{(r.effective_state || '').replace(/_/g, ' ')}</span>{r.payment_hold ? <span className="hold">HOLD</span> : null}</td>
            </tr>
          ))}
          {rows.length === 0 && <tr><td colSpan={6} className="loading">No invoices in this view.</td></tr>}
        </tbody>
      </table>

      {/* per-disposition approve/reject explainers */}
      <div className="sec-title" style={{ marginTop: 30 }}>What happens on Approve / Reject</div>
      <div className="explainers">
        {ACTION_EXPLAINERS.map(e => (
          <div className="ex-card" key={e.type}>
            <div className="ex-head"><span className={'pill ' + e.type}>{e.label}</span></div>
            <div className="ex-row"><span className="ex-lbl approve">Approve</span>{e.approve}</div>
            <div className="ex-row"><span className="ex-lbl reject">Reject</span>{e.reject}</div>
          </div>
        ))}
      </div>

      {sel && <Drawer id={sel} onClose={() => setSel(null)} onDecided={() => { setSel(null); refresh() }} />}
      <Chat />
    </div>
  )
}

function Drawer({ id, onClose, onDecided }: { id: string, onClose: () => void, onDecided: () => void }) {
  const [data, setData] = useState<any>(null)
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  useEffect(() => { fetch('/api/invoice/' + id).then(r => r.json()).then(setData) }, [id])

  const decide = (action: string) => {
    setBusy(true); setErr('')
    fetch(`/api/invoice/${id}/decide`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action, approver: 'controller@company.com', approver_role: data?.header?.assigned_approver_role || 'MANAGER', note }),
    }).then(async r => { if (!r.ok) { const e = await r.json(); throw new Error(e.detail || 'failed') } onDecided() })
      .catch(e => { setErr(e.message); setBusy(false) })
  }

  if (!data) return (<div className="overlay" onClick={onClose}><div className="drawer"><div className="loading">Loading…</div></div></div>)
  const h = data.header
  const pending = h.effective_state === 'PENDING_APPROVAL'
  const src = h.email_thread || h.email_note
  return (
    <div className="overlay" onClick={onClose}>
      <div className="drawer" onClick={e => e.stopPropagation()}>
        <button className="close" onClick={onClose}>×</button>
        <h2>{h.invoice_number} <span className={'pill ' + h.disposition} style={{ marginLeft: 8 }}>{(h.disposition || '').replace(/_/g, ' ')}</span>
          {h.payment_hold ? <span className="hold" style={{ marginLeft: 8 }}>HOLD</span> : null}</h2>
        <div style={{ color: 'var(--muted)', fontSize: 13 }}>{h.vendor_name} · {h.vendor_category} · {fmt(h.invoice_amount)}</div>

        <div className="modal-body">
          {/* LEFT: how the exception was found, then read */}
          <div className="modal-col">
            {/* Level 1 — deterministic */}
            <div className="finding">
              <div className="cap">Step 1 · 3-way match <span className="step">— deterministic (SQL)</span></div>
              <div className="txt">{h.match_finding}</div>
              <div className="legs">
                <div className={'leg ' + (h.leg_po_ok ? 'ok' : 'bad')}><div className="lt">PO</div><div className="lv">{h.leg_po_ok ? '✓ matched' : '✗ missing'}</div></div>
                <div className={'leg ' + (h.leg_grn_ok ? 'ok' : 'bad')}><div className="lt">Goods receipt</div><div className="lv">{h.leg_grn_ok ? '✓ matched' : '✗ missing'}</div></div>
                <div className={'leg ' + (h.leg_amount_ok ? 'ok' : 'bad')}><div className="lt">Amount</div><div className="lv">{h.leg_amount_ok ? '✓ in line' : '✗ variance'}</div></div>
              </div>
            </div>

            {/* Level 2 — AI reading */}
            <div className="rec">
              <div className="cap">Step 2 · Reason from the correspondence <span className="step">— AI</span></div>
              {h.business_reason && <div style={{ fontWeight: 600, marginBottom: 6 }}>{h.business_reason}</div>}
              {h.evidence_reason && <div style={{ color: 'var(--muted)', fontSize: 12 }}>{h.evidence_reason}</div>}
            </div>

            {src && (
              <div className="sources">
                <div className="cap">Source documents the AI read</div>
                {h.email_thread && <><div className="src-label">📧 Email thread</div><pre className="thread">{h.email_thread}</pre></>}
                {!h.email_thread && h.email_note && <><div className="src-label">📧 Email note</div><pre className="thread">{h.email_note}</pre></>}
                {h.po_comment && <><div className="src-label">📝 Purchase-order comment</div><div className="src-body">{h.po_comment}</div></>}
                {h.invoice_memo && <><div className="src-label">🧾 Invoice memo</div><div className="src-body">{h.invoice_memo}</div></>}
              </div>
            )}
          </div>

          {/* RIGHT: contract check, facts, line detail, decision */}
          <div className="modal-col">
            {h.contract_verdict && <div className={'contract ' + h.contract_verdict}>
              <div className="cap">Step 3 · Contract validation — {h.contract_verdict === 'WITHIN_CONTRACT' ? 'within contract' : 'BREACH'}</div>
              <div>Actual increase <b>{h.price_variance_pct}%</b> vs contracted cap <b>{h.contract_allowed_pct != null ? h.contract_allowed_pct + '%' : '—'}</b></div>
              {h.contract_clause && <div style={{ marginTop: 6, fontSize: 12, color: 'var(--muted)' }}>Cited clause: “{h.contract_clause}”</div>}
            </div>}

            <div className="kv">
              <div className="k">Disposition</div><div className="v">{(h.disposition || '').replace(/_/g, ' ')} {h.classify_confidence != null && <span style={{ color: 'var(--muted)' }}>({Math.round(h.classify_confidence * 100)}%)</span>}</div>
              <div className="k">Routed to</div><div className="v">{h.assigned_approver_role || '— (auto / touchless)'}</div>
              <div className="k">Outcome</div><div className="v"><span className={'state ' + h.effective_state}>{(h.effective_state || '').replace(/_/g, ' ')}</span></div>
              {h.duplicate_of_invoice_id && <><div className="k">Duplicate of</div><div className="v mono">{h.duplicate_of_invoice_id}</div></>}
            </div>

            <div>
              <div className="sec-title" style={{ marginTop: 0 }}>Line-level match</div>
              <table className="lines">
                <thead><tr><th>SKU</th><th>Inv qty</th><th>Recv</th><th>Inv price</th><th>PO price</th><th>Price Δ</th><th>Qty Δ</th></tr></thead>
                <tbody>
                  {data.lines.map((l: any) => (
                    <tr key={l.line_no}>
                      <td className="mono">{l.sku}</td><td className="right mono">{l.invoiced_qty}</td>
                      <td className="right mono">{l.received_qty ?? '—'}</td><td className="right mono">{l.invoiced_unit_price}</td>
                      <td className="right mono">{l.po_unit_price ?? '—'}</td>
                      <td className={'right mono' + (Math.abs(l.price_var_pct) >= 5 ? ' bad' : '')}>{l.price_var_pct ?? '—'}%</td>
                      <td className={'right mono' + (Math.abs(l.qty_var_pct) >= 5 ? ' bad' : '')}>{l.qty_var_pct ?? '—'}%</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {data.history.length > 0 && <div><div className="sec-title">Decision history</div>
              {data.history.map((x: any, i: number) => (<div className="histrow" key={i}>{x.action} by {x.approver} ({x.approver_role}) · {x.note || 'no note'}</div>))}</div>}

            <div style={{ marginTop: 'auto' }}>
              {h.payment_hold && <div className="holdbar">⛔ Hard duplicate hold — cannot be approved until the duplicate is cleared.</div>}
              {pending && !h.payment_hold && <>
                <textarea className="note" placeholder="Approval note (optional)…" value={note} onChange={e => setNote(e.target.value)} />
                {err && <div className="holdbar">{err}</div>}
                <div className="actions">
                  <button className="btn approve" disabled={busy} onClick={() => decide('APPROVE')}>Approve</button>
                  <button className="btn reject" disabled={busy} onClick={() => decide('REJECT')}>Reject</button>
                </div>
              </>}
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}

type Msg = { role: 'user' | 'bot', text: string, streaming?: boolean }

// ── lightweight markdown renderer for chat answers ──
// inline: **bold**, `code`; block: markdown tables, -/• bullets, plain paragraphs.
function inlineMd(s: string, key: any) {
  const nodes: any[] = []
  const re = /\*\*([^*]+)\*\*|`([^`]+)`/g
  let last = 0, m: RegExpExecArray | null, k = 0
  while ((m = re.exec(s))) {
    if (m.index > last) nodes.push(s.slice(last, m.index))
    if (m[1]) nodes.push(<b key={key + '-' + k++}>{m[1]}</b>)
    else nodes.push(<code key={key + '-' + k++}>{m[2]}</code>)
    last = m.index + m[0].length
  }
  if (last < s.length) nodes.push(s.slice(last))
  return nodes
}
function ChatMd({ text }: { text: string }) {
  const lines = text.split('\n')
  const els: any[] = []
  let i = 0, k = 0
  const isRow = (l: string) => l.trim().startsWith('|') && l.trim().endsWith('|')
  const isSep = (l: string) => /^\|[\s\-|:]+\|$/.test(l.trim())
  const cells = (l: string) => l.trim().slice(1, -1).split('|').map(c => c.trim())
  const isBullet = (l: string) => /^[-*•]\s/.test(l.trim())
  while (i < lines.length) {
    const t = lines[i].trim()
    if (!t) { i++; continue }
    if (isRow(lines[i])) {
      const tl: string[] = []
      while (i < lines.length && (isRow(lines[i]) || isSep(lines[i]))) { if (lines[i].trim()) tl.push(lines[i]); i++ }
      if (tl.length) {
        const hdr = cells(tl[0]); const start = tl.length > 1 && isSep(tl[1]) ? 2 : 1
        const rows = tl.slice(start).filter(isRow).map(cells)
        els.push(<table className="chat-tbl" key={k++}><thead><tr>{hdr.map((h, j) => <th key={j}>{inlineMd(h, 'h' + j)}</th>)}</tr></thead>
          <tbody>{rows.map((r, ri) => <tr key={ri}>{hdr.map((_, ci) => <td key={ci}>{inlineMd(r[ci] ?? '', 'c' + ri + ci)}</td>)}</tr>)}</tbody></table>)
      }
      continue
    }
    if (isBullet(t)) {
      const items: string[] = []
      while (i < lines.length && isBullet(lines[i].trim())) { items.push(lines[i].trim().replace(/^[-*•]\s/, '')); i++ }
      els.push(<ul className="chat-ul" key={k++}>{items.map((it, j) => <li key={j}>{inlineMd(it, 'l' + j)}</li>)}</ul>)
      continue
    }
    els.push(<p className="chat-p" key={k++}>{inlineMd(t, 'p' + k)}</p>)
    i++
  }
  return <>{els}</>
}

function Chat() {
  const [open, setOpen] = useState(false)
  const [msgs, setMsgs] = useState<Msg[]>([{ role: 'bot', text: 'Ask about the invoices and exceptions, or about a vendor’s contract terms.' }])
  const [q, setQ] = useState('')
  const [busy, setBusy] = useState(false)
  const histRef = useRef<any[]>([])
  const endRef = useRef<HTMLDivElement>(null)
  useEffect(() => { endRef.current?.scrollIntoView({ behavior: 'smooth' }) }, [msgs, open])

  const send = async () => {
    if (!q.trim() || busy) return
    const question = q.trim()
    // add the user turn + an empty bot bubble we stream into
    setMsgs(m => [...m, { role: 'user', text: question }, { role: 'bot', text: '', streaming: true }])
    setQ(''); setBusy(true)
    try {
      const resp = await fetch('/api/chat', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ question, history: histRef.current }),
      })
      if (!resp.ok || !resp.body) throw new Error('HTTP ' + resp.status)
      const reader = resp.body.getReader()
      const decoder = new TextDecoder()
      let buf = ''
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        buf += decoder.decode(value, { stream: true })
        const parts = buf.split('\n\n'); buf = parts.pop() ?? ''
        for (const part of parts) {
          for (const line of part.split('\n')) {
            if (!line.startsWith('data: ')) continue
            let d: any; try { d = JSON.parse(line.slice(6)) } catch { continue }
            if (d.type === 'chunk') {
              setMsgs(m => { const last = m[m.length - 1]; if (last?.role !== 'bot') return m
                return [...m.slice(0, -1), { ...last, text: last.text + d.text }] })
            } else if (d.type === 'done') {
              if (d.history) histRef.current = d.history
              setMsgs(m => { const last = m[m.length - 1]; if (last?.role !== 'bot') return m
                return [...m.slice(0, -1), { ...last, streaming: false }] })
            } else if (d.type === 'error') {
              setMsgs(m => [...m.slice(0, -1), { role: 'bot', text: 'Sorry — ' + (d.message || 'something went wrong.') }])
            }
          }
        }
      }
    } catch {
      setMsgs(m => [...m.slice(0, -1), { role: 'bot', text: 'Sorry — something went wrong.' }])
    } finally { setBusy(false) }
  }

  return (
    <>
      <button className="chat-fab" onClick={() => setOpen(!open)}>{open ? '×' : '💬 Ask'}</button>
      {open && (
        <div className="chat-panel">
          <div className="chat-head">P2P Assistant <span className="chat-sub">Invoices, exceptions & contract terms</span></div>
          <div className="chat-body">
            {msgs.map((m, i) => (
              <div key={i} className={'msg ' + m.role}>
                <div className="bubble">
                  {m.role === 'bot'
                    ? (m.text ? <><ChatMd text={m.text} />{m.streaming && <span className="cursor" />}</> : <span className="dots">…</span>)
                    : m.text}
                </div>
              </div>
            ))}
            <div ref={endRef} />
          </div>
          <div className="chat-input">
            <input value={q} onChange={e => setQ(e.target.value)} onKeyDown={e => e.key === 'Enter' && send()} placeholder="e.g. total on duplicate hold, or what's Cyberdyne's price cap?" />
            <button onClick={send} disabled={busy}>Send</button>
          </div>
        </div>
      )}
    </>
  )
}

export default App
