"""
Power BI service layer — token acquisition, embed tokens, DAX execution.

Authentication modes for DAX executeQueries (requires a delegated/user token):
  - azcli: uses `az login` session (dev/testing only)
  - ropc:  Resource Owner Password Credentials — "Master User" approach.
           Stores service account email + password to get a delegated token.
           Account must NOT have MFA.  App registration must allow public
           client flows.

Service Principals and Managed Identities use client-credentials flow, which
does NOT provide a user context.  The executeQueries endpoint returns 401
because Dataset.ReadWrite.All is a delegated-only permission.
"""

from __future__ import annotations

import logging
import re
from typing import Any

import httpx
import msal
from azure.identity import AzureCliCredential

from config import settings, get_rls_config

logger = logging.getLogger(__name__)

PBI_RESOURCE = "https://analysis.windows.net/powerbi/api/.default"
PBI_BASE = "https://api.powerbi.com/v1.0/myorg"

# ---------------------------------------------------------------------------
# Token acquisition
# ---------------------------------------------------------------------------
_msal_app: msal.ConfidentialClientApplication | None = None
_cli_credential: AzureCliCredential | None = None
_ropc_app: msal.PublicClientApplication | None = None


def _get_msal_app() -> msal.ConfidentialClientApplication:
    """MSAL confidential app for Service Principal (embed tokens only)."""
    global _msal_app
    if _msal_app is None:
        _msal_app = msal.ConfidentialClientApplication(
            client_id=settings.azure_client_id,
            client_credential=settings.azure_client_secret,
            authority=f"https://login.microsoftonline.com/{settings.azure_tenant_id}",
        )
    return _msal_app


def get_access_token() -> str:
    """SP token for embed token generation."""
    app = _get_msal_app()
    result = app.acquire_token_for_client(scopes=[PBI_RESOURCE])
    if "access_token" not in result:
        raise RuntimeError(f"Token acquisition failed: {result.get('error_description')}")
    return result["access_token"]


def _get_azcli_token() -> str:
    """AzureCliCredential — uses `az login` session. Dev only."""
    global _cli_credential
    if _cli_credential is None:
        _cli_credential = AzureCliCredential()
    token = _cli_credential.get_token("https://analysis.windows.net/powerbi/api/.default")
    return token.token


def _get_ropc_token() -> str:
    """
    Resource Owner Password Credential (Master User) flow.
    Gets a delegated token using stored username + password.
    Requires DAX_USER_EMAIL and DAX_USER_PASSWORD in .env.
    App registration must have "Allow public client flows" enabled.
    """
    global _ropc_app
    if _ropc_app is None:
        _ropc_app = msal.PublicClientApplication(
            client_id=settings.azure_client_id,
            authority=f"https://login.microsoftonline.com/{settings.azure_tenant_id}",
        )

    # Try cache first
    accounts = _ropc_app.get_accounts(username=settings.dax_user_email)
    if accounts:
        result = _ropc_app.acquire_token_silent(
            scopes=["https://analysis.windows.net/powerbi/api/.default"],
            account=accounts[0],
        )
        if result and "access_token" in result:
            return result["access_token"]

    result = _ropc_app.acquire_token_by_username_password(
        username=settings.dax_user_email,
        password=settings.dax_user_password,
        scopes=["https://analysis.windows.net/powerbi/api/.default"],
    )
    if "access_token" not in result:
        raise RuntimeError(
            f"ROPC token failed: {result.get('error_description')}. "
            "Ensure DAX_USER_EMAIL/PASSWORD are correct, the account has no MFA, "
            "and the app registration allows public client flows."
        )
    return result["access_token"]


def get_dax_token() -> str:
    """
    Get a user-context token for DAX executeQueries.
    Dispatches based on DAX_AUTH_MODE setting.
    """
    mode = settings.dax_auth_mode.lower()
    if mode == "ropc":
        return _get_ropc_token()
    elif mode == "azcli":
        return _get_azcli_token()
    else:
        raise RuntimeError(
            f"Unknown DAX_AUTH_MODE '{settings.dax_auth_mode}'. "
            "Supported: 'azcli' (dev), 'ropc' (master user)."
        )


# ---------------------------------------------------------------------------
# Embed token  (supports effective identity → RLS)
# ---------------------------------------------------------------------------

async def generate_embed_token(rls_username: str) -> dict[str, Any]:
    """
    Generate a Power BI embed token scoped to one report + dataset,
    with effective identity carrying the RLS username.
    """
    access_token = get_access_token()

    # Direct Lake datasets require V2 embed tokens (multi-resource endpoint)
    url = f"{PBI_BASE}/GenerateToken"
    body = {
        "datasets": [{"id": settings.pbi_dataset_id}],
        "reports": [{"id": settings.pbi_report_id, "allowEdit": False}],
        "targetWorkspaces": [{"id": settings.pbi_workspace_id}],
        # Allow client-side DAX execution via report.executeQuery()
        "datasetsAccessLevel": "ReadWriteReshareExplore",
        "identities": [
            {
                "username": rls_username,
                "roles": [settings.pbi_rls_role],
                "datasets": [settings.pbi_dataset_id],
            }
        ],
    }
    logger.info("GenerateToken request URL: %s", url)
    logger.info("GenerateToken request body: %s", body)

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            url,
            json=body,
            headers={"Authorization": f"Bearer {access_token}"},
            timeout=30,
        )
        if resp.status_code != 200:
            logger.error("GenerateToken failed %s: %s", resp.status_code, resp.text)
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

async def execute_dax(dax_query: str, rls_username: str = "") -> list[dict]:
    """
    Run a DAX query via the Power BI executeQueries API.
    Uses a user-context token (AzureCliCredential).

    RLS is enforced by wrapping the query with CALCULATETABLE + TREATAS
    filter based on the user's allowed sales territory regions.
    """
    token = get_dax_token()

    # Wrap query with RLS filter if we have a user identity
    final_dax = dax_query
    if rls_username:
        final_dax = await _wrap_dax_with_rls(dax_query, rls_username, token)

    url = (
        f"{PBI_BASE}/groups/{settings.pbi_workspace_id}"
        f"/datasets/{settings.pbi_dataset_id}/executeQueries"
    )
    body: dict[str, Any] = {
        "queries": [{"query": final_dax}],
        "serializerSettings": {"includeNulls": True},
    }

    logger.info("executeQueries URL: %s", url)
    logger.info("executeQueries DAX: %.300s", final_dax.strip())

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            url,
            json=body,
            headers={"Authorization": f"Bearer {token}"},
            timeout=60,
        )
        if resp.status_code == 200:
            return _parse_dax_response(resp.json())

        logger.error("executeQueries failed %s: %s", resp.status_code, resp.text[:500])
        resp.raise_for_status()
        return []


# ---------------------------------------------------------------------------
# RLS enforcement via DAX query wrapping  (config-driven)
# ---------------------------------------------------------------------------

_user_filter_cache: dict[str, list[str]] = {}


async def get_user_filter_values(rls_username: str, token: str) -> list[str]:
    """
    Look up which filter values a user can access, based on rls_config.json.
    Builds a DAX lookup query from config or uses custom_lookup_dax.
    Results are cached per user for the process lifetime.
    """
    if rls_username in _user_filter_cache:
        return _user_filter_cache[rls_username]

    rls = get_rls_config()
    if not rls.get("enabled"):
        return []

    # Build the lookup DAX
    custom = rls.get("custom_lookup_dax")
    if custom:
        dax = custom.replace("{username}", rls_username)
    else:
        ft = rls["filter_table"]
        fc = rls["filter_column"]
        it = rls["identity_table"]
        ic = rls["identity_column"]
        dax = (
            f"EVALUATE\n"
            f"CALCULATETABLE(\n"
            f"    VALUES('{ft}'[{fc}]),\n"
            f"    '{it}'[{ic}] = \"{rls_username}\"\n"
            f")"
        )

    url = (
        f"{PBI_BASE}/groups/{settings.pbi_workspace_id}"
        f"/datasets/{settings.pbi_dataset_id}/executeQueries"
    )
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            url,
            json={"queries": [{"query": dax}], "serializerSettings": {"includeNulls": True}},
            headers={"Authorization": f"Bearer {token}"},
            timeout=30,
        )

    values: list[str] = []
    if resp.status_code == 200:
        rows = _parse_dax_response(resp.json())
        ft = rls["filter_table"]
        fc = rls["filter_column"]
        for r in rows:
            # Try both qualified and short column names
            val = (
                r.get(f"{ft}[{fc}]")
                or r.get(f"'{ft}'[{fc}]")
                or r.get(f"[{fc}]")
            )
            if val:
                values.append(str(val))
    else:
        logger.warning("User filter lookup failed %s: %s", resp.status_code, resp.text[:200])

    _user_filter_cache[rls_username] = values
    logger.info("User %s filter values for %s[%s]: %s",
                rls_username, rls["filter_table"], rls["filter_column"], values)
    return values


async def _wrap_dax_with_rls(dax_query: str, rls_username: str, token: str) -> str:
    """
    Wrap a DAX EVALUATE query with CALCULATETABLE + TREATAS to enforce
    the RLS filter defined in rls_config.json.
    """
    rls = get_rls_config()
    if not rls.get("enabled"):
        return dax_query

    values = await get_user_filter_values(rls_username, token)
    if not values:
        logger.warning("No filter values for user %s — query will return no data", rls_username)
        return 'EVALUATE FILTER(ROW("NoAccess", 1), FALSE())'

    ft = rls["filter_table"]
    fc = rls["filter_column"]

    # Build the TREATAS value list (auto-detect numeric vs string)
    def _format_val(v: str) -> str:
        try:
            float(v)
            return v  # numeric — no quotes
        except ValueError:
            return f'"{v}"'

    value_list = ", ".join(_format_val(v) for v in values)

    stripped = dax_query.strip()
    has_define = re.match(r"(?i)^DEFINE\b", stripped)

    if has_define:
        wrapped = re.sub(
            r"(?i)\bEVALUATE\b",
            "EVALUATE\nCALCULATETABLE(\n",
            stripped,
            count=1,
        )
        wrapped += (
            f",\n    TREATAS({{{value_list}}}, '{ft}'[{fc}])\n)"
        )
    else:
        inner = re.sub(r"(?i)^EVALUATE\s+", "", stripped)
        wrapped = (
            f"EVALUATE\nCALCULATETABLE(\n    {inner},\n"
            f"    TREATAS({{{value_list}}}, '{ft}'[{fc}])\n)"
        )

    logger.info("RLS-wrapped DAX for %s (values=%s)", rls_username, values)
    return wrapped


def _parse_dax_response(data: dict) -> list[dict]:
    """Parse the executeQueries / queryExecution response into row dicts."""
    results = data.get("results", [])
    if not results:
        return []
    tables = results[0].get("tables", [])
    if not tables:
        return []
    return tables[0].get("rows", [])


# ---------------------------------------------------------------------------
# Retrieve dataset schema (tables + columns) for LLM context
# ---------------------------------------------------------------------------

_schema_cache: dict[str, Any] | None = None


async def get_dataset_schema() -> dict[str, Any]:
    """
    Fetch the dataset tables + columns + measures.
    Priority:
      1. Static schema file (sample_report/schema.json) — always works
      2. DAX COLUMNSTATISTICS() + INFO.MEASURES() — needs Build permission
    """
    global _schema_cache
    if _schema_cache is not None:
        return _schema_cache

    # --- Try loading a static schema file first ---
    import pathlib, json as _json
    schema_path = pathlib.Path(__file__).parent / "sample_report" / "schema.json"
    if schema_path.exists():
        try:
            _schema_cache = _json.loads(schema_path.read_text())
            logger.info("Schema loaded from %s: %d tables", schema_path, len(_schema_cache.get("tables", [])))
            return _schema_cache
        except Exception as e:
            logger.warning("Failed to load static schema: %s", e)

    tables_map: dict[str, dict[str, list[str]]] = {}

    # --- Discover columns via COLUMNSTATISTICS() ---
    try:
        col_dax = """
            EVALUATE
            SELECTCOLUMNS(
                COLUMNSTATISTICS(),
                "TableName", [Table Name],
                "ColumnName", [Column Name],
                "MinValue", [Min],
                "MaxValue", [Max]
            )
        """
        col_rows = await execute_dax(col_dax, rls_username="")
        for r in col_rows:
            tname = r.get("[TableName]", "")
            cname = r.get("[ColumnName]", "")
            if not tname or not cname:
                continue
            if tname not in tables_map:
                tables_map[tname] = {"columns": [], "measures": []}
            tables_map[tname]["columns"].append(cname)
        logger.info("Schema columns loaded via COLUMNSTATISTICS: %d tables", len(tables_map))
    except Exception as e:
        logger.warning("COLUMNSTATISTICS failed: %s", e)

    # --- Discover measures via INFO.MEASURES() ---
    try:
        msr_dax = """
            EVALUATE
            SELECTCOLUMNS(
                INFO.MEASURES(),
                "TableName", [TableName],
                "MeasureName", [Name]
            )
        """
        msr_rows = await execute_dax(msr_dax, rls_username="")
        for r in msr_rows:
            tname = r.get("[TableName]", "")
            mname = r.get("[MeasureName]", "")
            if not tname or not mname:
                continue
            if tname not in tables_map:
                tables_map[tname] = {"columns": [], "measures": []}
            tables_map[tname]["measures"].append(mname)
        logger.info("Schema measures loaded via INFO.MEASURES")
    except Exception as e:
        logger.warning("INFO.MEASURES failed: %s", e)

    _schema_cache = {
        "tables": [
            {"name": t, "columns": v["columns"], "measures": v["measures"]}
            for t, v in tables_map.items()
        ]
    }
    logger.info("Schema loaded: %d tables", len(_schema_cache["tables"]))
    return _schema_cache
