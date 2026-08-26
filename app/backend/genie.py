"""Genie chat helper — asks the P2P Intelligence Genie space and returns a
natural-language answer plus any tabular result, using the Databricks SDK."""
import os
from backend.config import w

GENIE_SPACE_ID = os.environ.get("GENIE_SPACE_ID", "01f187d18e7f1defbc719ddabafae0c6")


def _extract(msg) -> dict:
    """Pull answer text + optional query (SQL + result rows) out of a Genie message."""
    text_parts, sql, desc = [], None, None
    for a in (msg.attachments or []):
        if getattr(a, "text", None) and a.text.content:
            text_parts.append(a.text.content)
        if getattr(a, "query", None):
            sql = a.query.query
            desc = a.query.description
    return {"text": "\n\n".join(text_parts).strip(), "sql": sql, "description": desc}


def ask(question: str, conversation_id: str | None = None) -> dict:
    """Ask Genie a question. Returns {text, sql, description, rows, columns, conversation_id}."""
    g = w().genie
    if conversation_id:
        msg = g.create_message_and_wait(GENIE_SPACE_ID, conversation_id, question)
    else:
        msg = g.start_conversation_and_wait(GENIE_SPACE_ID, question)
        conversation_id = msg.conversation_id

    out = _extract(msg)
    out["conversation_id"] = conversation_id
    out["rows"], out["columns"] = [], []

    # If Genie produced a query, fetch the tabular result.
    try:
        for a in (msg.attachments or []):
            if getattr(a, "query", None):
                res = g.get_message_query_result_by_attachment(
                    GENIE_SPACE_ID, conversation_id, msg.message_id, a.attachment_id)
                sr = res.statement_response
                if sr and sr.result and sr.result.data_array:
                    out["rows"] = sr.result.data_array[:100]
                    if sr.manifest and sr.manifest.schema:
                        out["columns"] = [c.name for c in sr.manifest.schema.columns]
                break
    except Exception as e:
        out["result_error"] = str(e)

    if not out["text"] and out["rows"]:
        out["text"] = "Here are the results:"
    if not out["text"]:
        out["text"] = "I couldn't find an answer for that."
    return out
