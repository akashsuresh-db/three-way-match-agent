"""Config + dual-mode auth for the 3-Way Match Agent app."""
import os
from databricks.sdk import WorkspaceClient

IS_DATABRICKS_APP = bool(os.environ.get("DATABRICKS_APP_NAME"))

CATALOG = os.environ.get("APP_CATALOG", "lakemeter_demo_catalog")
SCHEMA = os.environ.get("APP_SCHEMA", "three_way_match")
WAREHOUSE_ID = os.environ.get("DATABRICKS_WAREHOUSE_ID", "59003c369444b958")
PROFILE = os.environ.get("DATABRICKS_CONFIG_PROFILE", "fevm-lakemeter-demo")

_client: WorkspaceClient | None = None


def w() -> WorkspaceClient:
    global _client
    if _client is None:
        _client = WorkspaceClient() if IS_DATABRICKS_APP else WorkspaceClient(profile=PROFILE)
    return _client


def fq(table: str) -> str:
    return f"`{CATALOG}`.`{SCHEMA}`.`{table}`"
