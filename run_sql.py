#!/usr/bin/env python3
"""Execute .sql files (semicolon-separated statements) against the FEVM warehouse.

Usage: python run_sql.py <file.sql> [file2.sql ...]
       python run_sql.py -c "SELECT 1"
"""
import sys
from databricks.sdk import WorkspaceClient
from databricks.sdk.service.sql import StatementState

PROFILE = "fevm-lakemeter-demo"
WAREHOUSE_ID = "59003c369444b958"
CATALOG = "lakemeter_demo_catalog"
SCHEMA = "three_way_match"

w = WorkspaceClient(profile=PROFILE)


def _strip_line_comment(line: str) -> str:
    """Remove a trailing `-- ...` comment (no string-literal handling; safe for
    this controlled SQL which never embeds `--` inside a string)."""
    idx = line.find("--")
    return line[:idx] if idx >= 0 else line


def split_statements(sql: str):
    """Split on ';' at the end of a statement's *code* (trailing comments removed)."""
    stmts, buf = [], []
    for line in sql.splitlines():
        code = _strip_line_comment(line).rstrip()
        if not code and not buf:
            continue  # skip blank / comment-only lines between statements
        buf.append(line)
        if code.endswith(";"):
            chunk = "\n".join(buf).strip()
            # drop the terminating semicolon from the last code line
            chunk = chunk.rstrip()
            if chunk.endswith(";"):
                chunk = chunk[:-1]
            chunk = chunk.strip()
            if chunk:
                stmts.append(chunk)
            buf = []
    tail = "\n".join(buf).strip().rstrip(";").strip()
    if tail:
        stmts.append(tail)
    return stmts


def run(stmt: str, show: bool = True):
    resp = w.statement_execution.execute_statement(
        warehouse_id=WAREHOUSE_ID,
        catalog=CATALOG,
        schema=SCHEMA,
        statement=stmt,
        wait_timeout="50s",
    )
    # poll if still running
    while resp.status.state in (StatementState.PENDING, StatementState.RUNNING):
        resp = w.statement_execution.get_statement(resp.statement_id)
    if resp.status.state != StatementState.SUCCEEDED:
        raise RuntimeError(f"FAILED: {resp.status.error.message if resp.status.error else resp.status.state}\n--SQL--\n{stmt[:500]}")
    if show and resp.result and resp.result.data_array:
        cols = [c.name for c in resp.manifest.schema.columns]
        print("  " + " | ".join(cols))
        for row in resp.result.data_array[:50]:
            print("  " + " | ".join(str(v) for v in row))
    return resp


def main():
    args = sys.argv[1:]
    if args and args[0] == "-c":
        run(args[1])
        return
    for path in args:
        with open(path) as f:
            stmts = split_statements(f.read())
        print(f"=== {path}: {len(stmts)} statements ===")
        for i, s in enumerate(stmts, 1):
            preview = " ".join(s.split())[:70]
            print(f"[{i}/{len(stmts)}] {preview}")
            run(s, show=True)
    print("DONE")


if __name__ == "__main__":
    main()
