"""Ask-anything chat backed by the Agent Bricks Supervisor (mas-fd473d0a-endpoint).

The same Supervisor that validates contracts in the pipeline also powers the app's
Ask widget. It routes each question to its sub-agents — the Genie space for data
questions over the P2P gold tables, the Knowledge Assistant for contract/clause
questions — and synthesises the answer.

The endpoint is task type agent/v1/responses (stateless per call), so multi-turn
context is carried by replaying prior turns in the `input` array.
"""
import os
import re
import json
from backend.config import w

SUPERVISOR_ENDPOINT = os.environ.get("SUPERVISOR_ENDPOINT", "mas-fd473d0a-endpoint")


def _clean(t: str) -> str:
    """Strip stray sub-agent name tags the Supervisor sometimes emits."""
    t = re.sub(r"</?name>[^<]*</name>|</?name>", "", t)
    return t


def _messages(question: str, history: list | None):
    msgs = []
    for turn in (history or [])[-6:]:
        role = "assistant" if turn.get("role") == "bot" else "user"
        msgs.append({"role": role, "content": turn.get("text", "")})
    msgs.append({"role": "user", "content": question})
    return msgs


def _iter_answer_deltas(msgs: list):
    """Call the endpoint with stream:true and yield final-answer text deltas LIVE.

    The responses stream interleaves the agent's tool-routing narration ("I'll
    query the … agent", which resolves into a function_call) with the final
    synthesised answer. Strategy: stream text deltas per item_id, but hold each
    item's text until we know it is NOT a function_call. In practice the answer
    is the message that follows the tool calls, so we:
      • track deltas per item_id,
      • when an item completes as a 'function_call', drop its buffered text
        and remember its id as chatter,
      • stream deltas live for any item that is not (yet) known chatter, and
        once a function_call has occurred, only stream the post-tool message.
    We yield (text_delta) strings; the caller wraps them as SSE chunks.
    """
    import requests
    cfg = w().config
    headers = {"Content-Type": "application/json"}
    headers.update(cfg.authenticate())
    url = f"{cfg.host.rstrip('/')}/serving-endpoints/{SUPERVISOR_ENDPOINT}/invocations"

    tool_seen = False          # have we passed the routing/tool phase?
    chatter_ids: set[str] = set()
    pre_tool_buf: dict[str, str] = {}   # item_id -> text, for the no-tool fallback
    streamed_any = False
    with requests.post(url, headers=headers, json={"input": msgs, "stream": True},
                       stream=True, timeout=180) as r:
        r.raise_for_status()
        for raw in r.iter_lines(decode_unicode=True):
            if not raw or not raw.startswith("data: "):
                continue
            try:
                d = json.loads(raw[6:])
            except Exception:
                continue
            t = d.get("type")
            if t == "response.output_text.delta":
                iid = d.get("item_id") or "_"
                if iid in chatter_ids:
                    continue
                piece = _clean(d.get("delta") or d.get("text") or "")
                if tool_seen:
                    # after routing: this is the final answer — stream it live
                    if piece:
                        streamed_any = True
                        yield piece
                else:
                    # before any tool call: hold, in case this is a no-tool answer
                    pre_tool_buf[iid] = pre_tool_buf.get(iid, "") + piece
            elif t == "response.output_item.done":
                it = d.get("item", {}) or {}
                if it.get("type") == "function_call":
                    tool_seen = True
                    chatter_ids.add(it.get("id"))
                    pre_tool_buf.pop(it.get("id"), None)   # drop routing narration
            elif t in ("response.completed", "response.done"):
                break
    # no tool was ever called (e.g. a greeting): emit the held answer text
    if not streamed_any and pre_tool_buf:
        yield "\n\n".join(v for v in pre_tool_buf.values() if v).strip()


def _extract_text(resp: dict) -> str:
    """Collect assistant output_text from a responses-API payload, skipping the
    agent's own tool-routing chatter and stray sub-agent name tags."""
    parts = []
    for item in (resp.get("output") or []):
        if item.get("type") != "message" or item.get("role") != "assistant":
            continue
        for c in (item.get("content") or []):
            if c.get("type") == "output_text" and c.get("text"):
                parts.append(c["text"])
    text = "\n\n".join(parts).strip()
    # strip sub-agent name markers like "<name>contract-information</name>"
    import re
    text = re.sub(r"</?name>[^<]*</name>|</?name>", "", text)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    return text


def ask(question: str, history: list | None = None) -> dict:
    """Ask the Supervisor. `history` is the prior [{role,text}] turns for context.
    Returns {text, history} where history includes this turn (for the next call)."""
    msgs = []
    for turn in (history or [])[-6:]:  # cap replayed context
        role = "assistant" if turn.get("role") == "bot" else "user"
        msgs.append({"role": role, "content": turn.get("text", "")})
    msgs.append({"role": "user", "content": question})

    client = w()
    resp = client.api_client.do(
        "POST",
        f"/serving-endpoints/{SUPERVISOR_ENDPOINT}/invocations",
        body={"input": msgs},
        headers={"Content-Type": "application/json"},
    )
    text = _extract_text(resp) or "I couldn't find an answer for that."
    new_history = (history or []) + [
        {"role": "user", "text": question},
        {"role": "bot", "text": text},
    ]
    return {"text": text, "history": new_history[-8:]}


def stream(question: str, history: list | None = None):
    """SSE generator for the Ask widget — streams the Supervisor's FINAL answer
    live (real token deltas), suppressing its tool-routing narration."""
    msgs = _messages(question, history)
    full = ""
    try:
        for piece in _iter_answer_deltas(msgs):
            if not piece:
                continue
            full += piece
            yield f"data: {json.dumps({'type': 'chunk', 'text': piece})}\n\n"
    except Exception as e:
        yield f"data: {json.dumps({'type': 'error', 'message': str(e)})}\n\n"
        return
    if not full.strip():
        full = "I couldn't find an answer for that."
        yield f"data: {json.dumps({'type': 'chunk', 'text': full})}\n\n"
    new_history = ((history or []) + [
        {"role": "user", "text": question},
        {"role": "bot", "text": full.strip()},
    ])[-8:]
    yield f"data: {json.dumps({'type': 'done', 'history': new_history})}\n\n"
