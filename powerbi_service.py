"""
Power BI service layer — token acquisition, embed tokens, DAX execution.
All calls use a service principal with effective identity for RLS.
"""

from __future__ import annotations

import logging
from typing import Any

import httpx
import msal

from config import settings

logger = logging.getLogger(__name__)

PBI_RESOURCE = "https://analysis.windows.net/powerbi/api/.default"
PBI_BASE = "https://api.powerbi.com/v1.0/myorg"

# ---------------------------------------------------------------------------
# Token cache  (in-memory; production → Redis / distributed cache)
# ---------------------------------------------------------------------------
_msal_app: msal.ConfidentialClientApplication | None = None


def _get_msal_app() -> msal.ConfidentialClientApplication:
    global _msal_app
    if _msal_app is None:
        _msal_app = msal.ConfidentialClientApplication(
            client_id=settings.azure_client_id,
            client_credential=settings.azure_client_secret,
            authority=f"https://login.microsoftonline.com/{settings.azure_tenant_id}",
        )
    return _msal_app


def get_access_token() -> str:
    """Acquire an access token for the Power BI REST API via client credentials."""
    app = _get_msal_app()
    result = app.acquire_token_for_client(scopes=[PBI_RESOURCE])
    if "access_token" not in result:
        raise RuntimeError(f"Token acquisition failed: {result.get('error_description')}")
    return result["access_token"]


# ---------------------------------------------------------------------------
# Embed token  (supports effective identity → RLS)
# ---------------------------------------------------------------------------

async def generate_embed_token(rls_username: str) -> dict[str, Any]:
    """
    Generate a Power BI embed token scoped to one report + dataset,
    with effective identity carrying the RLS username.
    """
    access_token = get_access_token()

    url = f"{PBI_BASE}/GenerateToken"
    body = {
        "datasets": [{"id": settings.pbi_dataset_id}],
        "reports": [{"id": settings.pbi_report_id, "allowEdit": False}],
        "identities": [
            {
                "username": rls_username,
                "roles": [settings.pbi_rls_role],
                "datasets": [settings.pbi_dataset_id],
            }
        ],
    }

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            url,
            json=body,
            headers={"Authorization": f"Bearer {access_token}"},
            timeout=30,
        )
        resp.raise_for_status()
        data = resp.json()

    return {
        "embedToken": data["token"],
        "embedUrl": f"https://app.powerbi.com/reportEmbed?reportId={settings.pbi_report_id}&groupId={settings.pbi_workspace_id}",
        "reportId": settings.pbi_report_id,
    }


# ---------------------------------------------------------------------------
# Execute DAX queries with effective identity
# ---------------------------------------------------------------------------

async def execute_dax(dax_query: str, rls_username: str) -> list[dict]:
    """
    Run a DAX query against the dataset with effective identity for RLS.
    Returns a list of row dicts.
    """
    access_token = get_access_token()

    url = f"{PBI_BASE}/datasets/{settings.pbi_dataset_id}/executeQueries"
    body = {
        "queries": [{"query": dax_query}],
        "serializerSettings": {"includeNulls": True},
        "impersonatedUserName": rls_username,
    }

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            url,
            json=body,
            headers={"Authorization": f"Bearer {access_token}"},
            timeout=60,
        )
        if resp.status_code != 200:
            logger.error("DAX execute failed %s: %s", resp.status_code, resp.text)
            raise RuntimeError(f"DAX query failed ({resp.status_code}): {resp.text[:500]}")
        data = resp.json()

    # Parse the tabular result
    results = data.get("results", [])
    if not results:
        return []

    tables = results[0].get("tables", [])
    if not tables:
        return []

    rows = tables[0].get("rows", [])
    return rows


# ---------------------------------------------------------------------------
# Retrieve dataset schema (tables + columns) for LLM context
# ---------------------------------------------------------------------------

_schema_cache: dict[str, Any] | None = None


async def get_dataset_schema() -> dict[str, Any]:
    """Fetch the dataset tables + columns + measures via the Power BI REST API."""
    global _schema_cache
    if _schema_cache is not None:
        return _schema_cache

    access_token = get_access_token()

    # Get tables
    url = f"{PBI_BASE}/datasets/{settings.pbi_dataset_id}"
    async with httpx.AsyncClient() as client:
        # Discover tables via executeQueries with DMSCHEMA
        # Simpler: use the dataset details + a metadata DAX query
        dax = """
            EVALUATE
            UNION(
                SELECTCOLUMNS(
                    INFO.TABLES(),
                    "TableName", [Name],
                    "ObjectType", "Table"
                ),
                SELECTCOLUMNS(
                    INFO.COLUMNS(),
                    "TableName", [TableName],
                    "ObjectType", "Column: " & [ExplicitName]
                ),
                SELECTCOLUMNS(
                    INFO.MEASURES(),
                    "TableName", [TableName],
                    "ObjectType", "Measure: " & [Name]
                )
            )
        """
        try:
            rows = await execute_dax(dax, "schema_reader")
        except Exception:
            # Fallback: return an empty schema so the LLM still works
            logger.warning("Could not retrieve schema via DAX; using empty schema")
            _schema_cache = {"tables": []}
            return _schema_cache

    # Organise into a nested structure
    tables: dict[str, dict] = {}
    for row in rows:
        tname = row.get("[TableName]", "")
        otype = row.get("[ObjectType]", "")
        if tname not in tables:
            tables[tname] = {"columns": [], "measures": []}
        if otype.startswith("Column:"):
            tables[tname]["columns"].append(otype.replace("Column: ", ""))
        elif otype.startswith("Measure:"):
            tables[tname]["measures"].append(otype.replace("Measure: ", ""))

    _schema_cache = {"tables": [
        {"name": t, "columns": v["columns"], "measures": v["measures"]}
        for t, v in tables.items()
    ]}
    return _schema_cache
