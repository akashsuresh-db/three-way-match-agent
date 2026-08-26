"""Thin SQL execution helper over the Databricks SQL warehouse (Statement Execution API)."""
import uuid
from databricks.sdk.service.sql import StatementState
from backend.config import w, WAREHOUSE_ID, CATALOG, SCHEMA


def _coerce(val, type_name: str):
    """The Statement Execution API returns every cell as a string; coerce to a
    Python type using the column's declared type so booleans/numbers are usable."""
    if val is None:
        return None
    t = (type_name or "").upper()
    try:
        if t == "BOOLEAN":
            return val == "true" or val is True
        if t in ("INT", "LONG", "SHORT", "BYTE", "INTEGER", "BIGINT"):
            return int(val)
        if t in ("FLOAT", "DOUBLE", "DECIMAL"):
            return float(val)
    except (ValueError, TypeError):
        return val
    return val


def query(sql: str, params: list | None = None) -> list[dict]:
    """Run a SELECT and return list of dict rows (typed)."""
    resp = w().statement_execution.execute_statement(
        warehouse_id=WAREHOUSE_ID, catalog=CATALOG, schema=SCHEMA,
        statement=sql, parameters=params, wait_timeout="50s",
    )
    while resp.status.state in (StatementState.PENDING, StatementState.RUNNING):
        resp = w().statement_execution.get_statement(resp.statement_id)
    if resp.status.state != StatementState.SUCCEEDED:
        msg = resp.status.error.message if resp.status.error else str(resp.status.state)
        raise RuntimeError(msg)
    if not resp.manifest or not resp.manifest.schema or not resp.manifest.schema.columns:
        return []
    schema_cols = resp.manifest.schema.columns
    names = [c.name for c in schema_cols]
    types = [c.type_name.value if hasattr(c.type_name, "value") else str(c.type_name) for c in schema_cols]
    rows = resp.result.data_array if (resp.result and resp.result.data_array) else []
    return [{names[i]: _coerce(r[i], types[i]) for i in range(len(names))} for r in rows]


def execute(sql: str, params: list | None = None) -> None:
    """Run a non-SELECT (INSERT/MERGE). Raises on failure."""
    resp = w().statement_execution.execute_statement(
        warehouse_id=WAREHOUSE_ID, catalog=CATALOG, schema=SCHEMA,
        statement=sql, parameters=params, wait_timeout="50s",
    )
    while resp.status.state in (StatementState.PENDING, StatementState.RUNNING):
        resp = w().statement_execution.get_statement(resp.statement_id)
    if resp.status.state != StatementState.SUCCEEDED:
        msg = resp.status.error.message if resp.status.error else str(resp.status.state)
        raise RuntimeError(msg)


def new_id(prefix: str) -> str:
    return f"{prefix}-{uuid.uuid4().hex[:12]}"
