#!/usr/bin/env python3
"""
setup.py — Auto-discover dataset schema & detect RLS configuration.

Run once after configuring .env to generate:
  - sample_report/schema.json   (dataset tables, columns, measures)
  - rls_config.json             (RLS identity + filter mapping)

Usage:
    python setup.py          # Interactive — auto-detects then confirms
    python setup.py --auto   # Skip prompts, accept best-guess defaults
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import re
import sys
import time
from collections import deque
from typing import Any

ROOT = pathlib.Path(__file__).parent
SCHEMA_PATH = ROOT / "sample_report" / "schema.json"
RLS_PATH = ROOT / "rls_config.json"

PBI_BASE = "https://api.powerbi.com/v1.0/myorg"
FABRIC_BASE = "https://api.fabric.microsoft.com/v1"

# ---------------------------------------------------------------------------
# Terminal colours
# ---------------------------------------------------------------------------
GREEN = "\033[92m"
YELLOW = "\033[93m"
RED = "\033[91m"
BLUE = "\033[94m"
BOLD = "\033[1m"
DIM = "\033[2m"
END = "\033[0m"


def ok(msg: str) -> None:
    print(f"  {GREEN}✓{END} {msg}")


def warn(msg: str) -> None:
    print(f"  {YELLOW}⚠{END} {msg}")


def fail(msg: str) -> None:
    print(f"  {RED}✗{END} {msg}")


def info(msg: str) -> None:
    print(f"  {BLUE}ℹ{END} {msg}")


def step(n: int, total: int, msg: str) -> None:
    print(f"\n{BOLD}Step {n}/{total}: {msg}{END}")


def ask(prompt: str, default: str = "") -> str:
    """Prompt user for input with a default."""
    if default:
        raw = input(f"  {prompt} [{default}]: ").strip()
        return raw or default
    return input(f"  {prompt}: ").strip()


def ask_choice(prompt: str, options: list[str], default: int = 1) -> int:
    """Present numbered options and return the 1-based index chosen."""
    print(f"\n  {prompt}")
    for i, opt in enumerate(options, 1):
        marker = f" {BLUE}← suggested{END}" if i == default else ""
        print(f"    [{i}] {opt}{marker}")
    raw = input(f"  Choice [{default}]: ").strip()
    if not raw:
        return default
    try:
        choice = int(raw)
        if 1 <= choice <= len(options):
            return choice
    except ValueError:
        pass
    warn(f"Invalid choice, using default ({default})")
    return default


# ---------------------------------------------------------------------------
# Environment & Tokens
# ---------------------------------------------------------------------------

def load_env() -> dict[str, str]:
    """Load .env and validate required variables."""
    try:
        from dotenv import load_dotenv
        load_dotenv(ROOT / ".env")
    except ImportError:
        pass  # proceed with os.environ

    required = [
        "AZURE_TENANT_ID", "AZURE_CLIENT_ID", "AZURE_CLIENT_SECRET",
        "PBI_WORKSPACE_ID", "PBI_DATASET_ID",
    ]
    env: dict[str, str] = {}
    missing: list[str] = []
    for key in required:
        val = os.getenv(key, "")
        if not val:
            missing.append(key)
        env[key] = val

    # Optional keys
    for key in ["PBI_REPORT_ID", "PBI_RLS_ROLE", "DAX_AUTH_MODE",
                "DAX_USER_EMAIL", "DAX_USER_PASSWORD"]:
        env[key] = os.getenv(key, "")

    env.setdefault("PBI_RLS_ROLE", "ViewerRole")
    env.setdefault("DAX_AUTH_MODE", "azcli")

    print("\nChecking .env configuration...")
    if missing:
        fail(f"Missing required variables: {', '.join(missing)}")
        print("    Copy .env.example → .env and fill in your values.")
        sys.exit(1)

    ok(f"Tenant:    {env['AZURE_TENANT_ID'][:8]}…")
    ok(f"Workspace: {env['PBI_WORKSPACE_ID'][:8]}…")
    ok(f"Dataset:   {env['PBI_DATASET_ID'][:8]}…")
    ok(f"DAX auth:  {env['DAX_AUTH_MODE'] or 'azcli'}")
    return env


def acquire_tokens(env: dict[str, str]) -> dict[str, str]:
    """Acquire SP token + DAX (delegated) token."""
    import msal

    print("\nAcquiring tokens...")
    tokens: dict[str, str] = {}

    # --- SP token (client credentials) ---
    app = msal.ConfidentialClientApplication(
        client_id=env["AZURE_CLIENT_ID"],
        client_credential=env["AZURE_CLIENT_SECRET"],
        authority=f"https://login.microsoftonline.com/{env['AZURE_TENANT_ID']}",
    )
    result = app.acquire_token_for_client(
        scopes=["https://analysis.windows.net/powerbi/api/.default"]
    )
    if "access_token" in result:
        tokens["sp_pbi"] = result["access_token"]
        ok("Service principal token (Power BI scope)")
    else:
        fail(f"SP token failed: {result.get('error_description', '?')}")
        sys.exit(1)

    # Try Fabric scope for getDefinition API
    fab_result = app.acquire_token_for_client(
        scopes=["https://api.fabric.microsoft.com/.default"]
    )
    if "access_token" in fab_result:
        tokens["sp_fabric"] = fab_result["access_token"]
        ok("Service principal token (Fabric scope)")
    else:
        info("Fabric scope not available — will use heuristics for RLS detection")

    # --- DAX token (delegated) ---
    mode = (env.get("DAX_AUTH_MODE") or "azcli").lower()
    if mode == "ropc":
        pub_app = msal.PublicClientApplication(
            client_id=env["AZURE_CLIENT_ID"],
            authority=f"https://login.microsoftonline.com/{env['AZURE_TENANT_ID']}",
        )
        result = pub_app.acquire_token_by_username_password(
            username=env["DAX_USER_EMAIL"],
            password=env["DAX_USER_PASSWORD"],
            scopes=["https://analysis.windows.net/powerbi/api/.default"],
        )
        if "access_token" in result:
            tokens["dax"] = result["access_token"]
            ok("DAX token (ROPC/Master User)")
        else:
            fail(f"ROPC failed: {result.get('error_description', '?')}")
            sys.exit(1)
    else:
        try:
            from azure.identity import AzureCliCredential
            cred = AzureCliCredential()
            tok = cred.get_token(
                "https://analysis.windows.net/powerbi/api/.default"
            )
            tokens["dax"] = tok.token
            ok("DAX token (az cli)")
        except Exception as e:
            fail(f"az cli token failed: {e}")
            print("    Run 'az login' first, or set DAX_AUTH_MODE=ropc in .env")
            sys.exit(1)

    return tokens


# ---------------------------------------------------------------------------
# Schema discovery via DAX
# ---------------------------------------------------------------------------

def discover_schema_dax(
    token: str, workspace_id: str, dataset_id: str
) -> dict[str, Any] | None:
    """Discover schema using COLUMNSTATISTICS() + INFO.MEASURES()."""
    import httpx

    url = (
        f"{PBI_BASE}/groups/{workspace_id}"
        f"/datasets/{dataset_id}/executeQueries"
    )
    headers = {"Authorization": f"Bearer {token}"}
    tables: dict[str, dict[str, list[str]]] = {}

    # --- Columns ---
    col_dax = """
    EVALUATE
    SELECTCOLUMNS(
        COLUMNSTATISTICS(),
        "TableName", [Table Name],
        "ColumnName", [Column Name]
    )
    """
    try:
        resp = httpx.post(
            url,
            json={
                "queries": [{"query": col_dax}],
                "serializerSettings": {"includeNulls": True},
            },
            headers=headers,
            timeout=30,
        )
    except Exception as e:
        fail(f"COLUMNSTATISTICS request failed: {e}")
        return None

    if resp.status_code != 200:
        fail(f"COLUMNSTATISTICS returned {resp.status_code}: {resp.text[:200]}")
        return None

    rows = (
        resp.json()
        .get("results", [{}])[0]
        .get("tables", [{}])[0]
        .get("rows", [])
    )
    for r in rows:
        tname = r.get("[TableName]", "")
        cname = r.get("[ColumnName]", "")
        if tname and cname:
            tables.setdefault(tname, {"columns": [], "measures": []})
            tables[tname]["columns"].append(cname)

    info(f"Found {len(tables)} tables, {sum(len(t['columns']) for t in tables.values())} columns")

    # --- Measures ---
    msr_dax = """
    EVALUATE
    SELECTCOLUMNS(
        INFO.MEASURES(),
        "TableName", [TableName],
        "MeasureName", [Name]
    )
    """
    try:
        resp = httpx.post(
            url,
            json={
                "queries": [{"query": msr_dax}],
                "serializerSettings": {"includeNulls": True},
            },
            headers=headers,
            timeout=30,
        )
        if resp.status_code == 200:
            mrows = (
                resp.json()
                .get("results", [{}])[0]
                .get("tables", [{}])[0]
                .get("rows", [])
            )
            mcount = 0
            for r in mrows:
                tname = r.get("[TableName]", "")
                mname = r.get("[MeasureName]", "")
                if tname and mname:
                    tables.setdefault(tname, {"columns": [], "measures": []})
                    tables[tname]["measures"].append(mname)
                    mcount += 1
            info(f"Found {mcount} measures")
        else:
            warn(f"INFO.MEASURES returned {resp.status_code} — skipping measures")
    except Exception:
        warn("INFO.MEASURES failed — skipping measures")

    # Filter out hidden system tables (DateTableTemplate, LocalDateTable)
    filtered = {
        t: v for t, v in tables.items()
        if not t.startswith("DateTableTemplate_")
        and not t.startswith("LocalDateTable_")
    }

    schema = {
        "tables": [
            {"name": t, "columns": v["columns"], "measures": v["measures"]}
            for t, v in sorted(filtered.items())
        ]
    }
    return schema


# ---------------------------------------------------------------------------
# TMDL fetching via Fabric getDefinition API
# ---------------------------------------------------------------------------

def fetch_tmdl(
    token: str, workspace_id: str, dataset_id: str
) -> dict[str, str] | None:
    """
    Fetch TMDL files via Fabric getDefinition API.
    Returns a dict of {path: decoded_content} or None on failure.
    """
    import httpx

    url = (
        f"{FABRIC_BASE}/workspaces/{workspace_id}"
        f"/semanticModels/{dataset_id}/getDefinition"
    )
    headers = {"Authorization": f"Bearer {token}"}

    try:
        resp = httpx.post(url, headers=headers, timeout=30)
    except Exception as e:
        info(f"Fabric API request failed: {e}")
        return None

    if resp.status_code == 200:
        return _decode_tmdl_parts(resp.json())

    if resp.status_code == 202:
        # Async — poll for completion
        location = resp.headers.get("Location", "")
        retry_after = int(resp.headers.get("Retry-After", "2"))
        if not location:
            info("getDefinition returned 202 but no Location header")
            return None

        info("Model definition is being prepared, polling…")
        for _ in range(30):
            time.sleep(max(retry_after, 2))
            try:
                poll = httpx.get(location, headers=headers, timeout=30)
            except Exception:
                continue
            if poll.status_code == 200:
                data = poll.json()
                status = data.get("status", "")
                if status == "Succeeded":
                    result_url = location.rstrip("/") + "/result"
                    try:
                        result = httpx.get(
                            result_url, headers=headers, timeout=30
                        )
                        if result.status_code == 200:
                            return _decode_tmdl_parts(result.json())
                    except Exception:
                        pass
                    return None
                if status in ("Failed", "Cancelled"):
                    info(f"getDefinition operation {status}")
                    return None
            elif poll.status_code != 202:
                break
        info("getDefinition polling timed out")
        return None

    info(f"getDefinition returned {resp.status_code} — using heuristics instead")
    return None


def _decode_tmdl_parts(payload: dict[str, Any]) -> dict[str, str]:
    """Decode base64 TMDL parts into {path: text_content}."""
    parts = payload.get("definition", {}).get("parts", [])
    files: dict[str, str] = {}
    for part in parts:
        path = part.get("path", "")
        raw = part.get("payload", "")
        ptype = part.get("payloadType", "")
        if ptype == "InlineBase64" and raw:
            try:
                files[path] = base64.b64decode(raw).decode("utf-8")
            except Exception:
                pass
    return files


# ---------------------------------------------------------------------------
# TMDL parsing — roles and relationships
# ---------------------------------------------------------------------------

def parse_tmdl_roles(
    tmdl_files: dict[str, str],
) -> list[dict[str, str]]:
    """
    Parse RLS role table permissions from TMDL.
    Returns list of {role, table, column, filter_expr}.
    """
    roles: list[dict[str, str]] = []

    for path, content in tmdl_files.items():
        # Look for files that define roles
        if not re.search(r"(?m)^role\s+", content):
            continue

        # Extract role name
        role_m = re.search(r"(?m)^role\s+'?([^'\n]+)'?\s*$", content)
        role_name = role_m.group(1).strip() if role_m else "Unknown"

        # Extract tablePermission lines
        # Format: tablePermission 'TableName' = <DAX filter expression>
        tp_matches = re.finditer(
            r"tablePermission\s+'?([^'=\n]+?)'?\s*=\s*(.+?)(?=\n\s*(?:tablePermission|annotation|\Z))",
            content,
            re.DOTALL,
        )
        for tp in tp_matches:
            table_name = tp.group(1).strip()
            filter_expr = tp.group(2).strip()

            # Try to extract the identity column from the filter expression
            # Patterns: [Col] = USERPRINCIPALNAME()  or  [Col] == USERNAME()
            col_m = re.search(
                r"\[(\w+)\]\s*={1,2}\s*(?:USERPRINCIPALNAME|USERNAME)\s*\(\s*\)",
                filter_expr,
                re.IGNORECASE,
            )
            column = col_m.group(1) if col_m else ""

            roles.append({
                "role": role_name,
                "table": table_name,
                "column": column,
                "filter_expr": filter_expr,
            })

    return roles


def parse_tmdl_relationships(
    tmdl_files: dict[str, str],
) -> list[dict[str, str]]:
    """
    Parse relationships from TMDL model file.
    Returns list of {from_table, from_column, to_table, to_column}.
    """
    relationships: list[dict[str, str]] = []

    for path, content in tmdl_files.items():
        # Relationships can be in relationships.tmdl, model.tmdl, or table files
        if "relationship" not in content.lower():
            continue

        # Split into relationship blocks (tab-indented or not)
        blocks = re.split(r"(?m)(?=^\s*relationship\s)", content)
        for block in blocks:
            if not re.match(r"\s*relationship\s", block):
                continue

            # TMDL format: fromColumn: Table.Column (no quotes typically)
            from_m = re.search(
                r"fromColumn:\s*'?([^'.\n]+?)'?\.(\w+)", block
            )
            to_m = re.search(
                r"toColumn:\s*'?([^'.\n]+?)'?\.(\w+)", block
            )
            if from_m and to_m:
                relationships.append({
                    "from_table": from_m.group(1).strip(),
                    "from_column": from_m.group(2).strip(),
                    "to_table": to_m.group(1).strip(),
                    "to_column": to_m.group(2).strip(),
                })

    return relationships


# ---------------------------------------------------------------------------
# Heuristic RLS detection (fallback when TMDL isn't available)
# ---------------------------------------------------------------------------

# Columns that likely store user identity
IDENTITY_COLUMN_HINTS = [
    "UPN", "UserPrincipalName", "UserEmail", "Email",
    "EmailAddress", "Username", "UserName", "LoginName",
    "UserID", "UserId",
]

# Tables that likely store user identity
IDENTITY_TABLE_HINTS = [
    "User", "Users", "Employee", "Employees", "Person", "People",
    "Identity", "Access", "UserAccess", "Member", "Members",
    "UserMapping", "RLSMapping",
]

# Tables/columns that are likely RLS filter targets
FILTER_TABLE_HINTS = [
    "Territory", "Territories", "SalesTerritor", "Region",
    "Department", "Departments", "Geography", "Country",
    "Division", "Group", "Segment", "Branch", "Office",
    "Store", "Location",
]

FILTER_COLUMN_HINTS = [
    "Region", "Territory", "TerritoryRegion", "SalesTerritoryRegion",
    "Department", "DepartmentName", "Country", "CountryName",
    "Division", "DivisionName", "Segment", "Branch", "Office",
    "StoreName", "Location", "Area",
]

# Tables to skip as filter targets
SKIP_TABLES = {"Calendar", "Date", "Dates", "Time"}


def _score_identity_table(
    table: dict[str, Any],
) -> tuple[int, str, str]:
    """
    Score a table as a potential identity table.
    Returns (score, table_name, best_column).
    Higher score = more likely.
    """
    tname = table["name"]
    columns = table.get("columns", [])
    score = 0
    best_col = ""
    best_col_score = 0

    # Table name match
    for hint in IDENTITY_TABLE_HINTS:
        if hint.lower() == tname.lower():
            score += 10
            break
        if hint.lower() in tname.lower():
            score += 5
            break

    # Column name match
    for col in columns:
        col_score = 0
        for hint in IDENTITY_COLUMN_HINTS:
            if hint.lower() == col.lower():
                col_score = 10
                break
            if hint.lower() in col.lower():
                col_score = 5
                break
        if col_score > best_col_score:
            best_col_score = col_score
            best_col = col

    score += best_col_score

    # Small tables are more likely identity tables
    if len(columns) <= 5:
        score += 2

    return score, tname, best_col


def _score_filter_candidate(
    table: dict[str, Any], identity_table: str
) -> list[tuple[int, str, str]]:
    """
    Score columns in a table as potential RLS filter targets.
    Returns list of (score, table_name, column_name).
    """
    tname = table["name"]
    columns = table.get("columns", [])
    candidates: list[tuple[int, str, str]] = []

    if tname == identity_table:
        return candidates
    if tname in SKIP_TABLES:
        return candidates

    # Table name scoring
    table_bonus = 0
    for hint in FILTER_TABLE_HINTS:
        if hint.lower() in tname.lower():
            table_bonus = 5
            break

    for col in columns:
        # Skip key/ID columns — they're joins, not natural filter targets
        if col.lower().endswith("key") or col.lower().endswith("id"):
            continue
        if col.lower() in ("key", "id"):
            continue

        score = table_bonus
        for hint in FILTER_COLUMN_HINTS:
            if hint.lower() == col.lower():
                score += 10
                break
            if hint.lower() in col.lower():
                score += 5
                break

        if score > 0:
            candidates.append((score, tname, col))

    return candidates


def detect_rls_from_tmdl(
    tmdl_files: dict[str, str],
) -> dict[str, str] | None:
    """
    Try to detect RLS config from TMDL.
    Returns {identity_table, identity_column, relationships} or None.
    """
    roles_info = parse_tmdl_roles(tmdl_files)
    rels = parse_tmdl_relationships(tmdl_files)

    if not roles_info:
        return None

    # Use the first role that has an identity column detected
    for r in roles_info:
        if r["column"]:
            result: dict[str, Any] = {
                "identity_table": r["table"],
                "identity_column": r["column"],
                "role": r["role"],
                "filter_expr": r["filter_expr"],
                "relationships": rels,
            }
            return result

    # If we found roles but couldn't parse the column
    return {
        "identity_table": roles_info[0]["table"],
        "identity_column": "",
        "role": roles_info[0]["role"],
        "filter_expr": roles_info[0].get("filter_expr", ""),
        "relationships": rels,
    }


def find_filter_candidates_from_rels(
    identity_table: str,
    relationships: list[dict[str, str]],
    schema: dict[str, Any],
) -> list[tuple[str, str]]:
    """
    BFS from identity table through relationships to find candidate
    filter tables/columns. Returns list of (table, column) pairs.
    """
    # Build adjacency graph
    graph: dict[str, list[str]] = {}
    for rel in relationships:
        ft = rel["from_table"]
        tt = rel["to_table"]
        graph.setdefault(ft, []).append(tt)
        graph.setdefault(tt, []).append(ft)

    # BFS from identity table (max depth 3)
    visited: set[str] = {identity_table}
    queue: deque[tuple[str, int]] = deque([(identity_table, 0)])
    reachable: list[str] = []

    while queue:
        table, depth = queue.popleft()
        if depth > 0:
            reachable.append(table)
        if depth < 3:
            for neighbor in graph.get(table, []):
                if neighbor not in visited:
                    visited.add(neighbor)
                    queue.append((neighbor, depth + 1))

    # Score reachable tables
    candidates: list[tuple[int, str, str]] = []
    table_map = {t["name"]: t for t in schema.get("tables", [])}
    for tname in reachable:
        if tname in table_map:
            candidates.extend(
                _score_filter_candidate(table_map[tname], identity_table)
            )

    candidates.sort(key=lambda x: -x[0])
    return [(t, c) for _, t, c in candidates]


def detect_rls_heuristic(
    schema: dict[str, Any],
) -> dict[str, Any]:
    """Heuristic RLS detection based on schema table/column names."""
    tables = schema.get("tables", [])

    # Score all tables as potential identity tables
    scored = [_score_identity_table(t) for t in tables]
    scored.sort(key=lambda x: -x[0])

    identity_candidates = [
        (tname, col) for score, tname, col in scored if score > 0 and col
    ]

    # Score all tables as potential filter targets
    filter_candidates: list[tuple[int, str, str]] = []
    best_identity = identity_candidates[0][0] if identity_candidates else ""
    for t in tables:
        filter_candidates.extend(
            _score_filter_candidate(t, best_identity)
        )
    filter_candidates.sort(key=lambda x: -x[0])

    return {
        "identity_candidates": identity_candidates,
        "filter_candidates": [(t, c) for _, t, c in filter_candidates],
    }


# ---------------------------------------------------------------------------
# Interactive RLS configuration
# ---------------------------------------------------------------------------

def configure_rls_interactive(
    schema: dict[str, Any],
    tmdl_info: dict[str, Any] | None,
    heuristic: dict[str, Any],
    auto: bool,
) -> dict[str, Any]:
    """
    Interactively (or automatically) configure RLS.
    Returns the rls_config dict ready to write.
    """
    identity_table = ""
    identity_column = ""
    filter_table = ""
    filter_column = ""
    description = ""

    # --- Identity table/column ---
    if tmdl_info and tmdl_info.get("identity_table"):
        identity_table = tmdl_info["identity_table"]
        identity_column = tmdl_info.get("identity_column", "")
        ok(f"Identity table detected from model: {identity_table}[{identity_column}]")
        if tmdl_info.get("role"):
            info(f"Role: {tmdl_info['role']}")
        if tmdl_info.get("filter_expr"):
            info(f"Filter: {tmdl_info['filter_expr']}")
    else:
        candidates = heuristic.get("identity_candidates", [])
        if candidates:
            if auto:
                identity_table, identity_column = candidates[0]
                ok(f"Identity table (auto): {identity_table}[{identity_column}]")
            else:
                options = [
                    f"{t}[{c}]" for t, c in candidates[:5]
                ] + ["Enter manually"]
                choice = ask_choice(
                    "Which table stores user identities (UPN/email)?",
                    options,
                )
                if choice <= len(candidates[:5]):
                    identity_table, identity_column = candidates[choice - 1]
                else:
                    identity_table = ask("Identity table name")
                    identity_column = ask("Identity column name")
        else:
            if auto:
                warn("Could not detect identity table — RLS will be disabled")
                return {"enabled": False}
            else:
                print("\n  Could not detect an identity table automatically.")
                identity_table = ask("Identity table name (or press Enter to skip)")
                if not identity_table:
                    return {"enabled": False}
                identity_column = ask("Identity column name")

    if not identity_column and not auto:
        # We have the table but not the column
        table_info = next(
            (t for t in schema.get("tables", []) if t["name"] == identity_table),
            None,
        )
        if table_info:
            cols = table_info.get("columns", [])
            options = cols[:6] + (["Enter manually"] if len(cols) > 6 else [])
            choice = ask_choice(
                f"Which column in {identity_table} identifies the user?",
                options if options else ["Enter manually"],
            )
            if choice <= min(len(cols), 6):
                identity_column = cols[choice - 1]
            else:
                identity_column = ask("Identity column name")
        else:
            identity_column = ask("Identity column name")

    # --- Filter table/column ---
    filter_candidates: list[tuple[str, str]] = []

    # Try relationship-based detection first
    if tmdl_info and tmdl_info.get("relationships"):
        filter_candidates = find_filter_candidates_from_rels(
            identity_table,
            tmdl_info["relationships"],
            schema,
        )
        if filter_candidates:
            info(f"Found {len(filter_candidates)} filter candidates via model relationships")

    # Fall back to heuristic
    if not filter_candidates:
        filter_candidates = heuristic.get("filter_candidates", [])

    if filter_candidates:
        if auto:
            filter_table, filter_column = filter_candidates[0]
            ok(f"Filter target (auto): {filter_table}[{filter_column}]")
        else:
            options = [
                f"{t}[{c}]" for t, c in filter_candidates[:5]
            ] + ["Enter manually"]
            choice = ask_choice(
                "Which table + column should DAX queries filter on?\n"
                "  (The security boundary your RLS model enforces)",
                options,
            )
            if choice <= len(filter_candidates[:5]):
                filter_table, filter_column = filter_candidates[choice - 1]
            else:
                filter_table = ask("Filter table name")
                filter_column = ask("Filter column name")
    else:
        if auto:
            warn("Could not detect filter table — RLS will be disabled")
            return {"enabled": False}
        else:
            print("\n  Could not detect a filter table automatically.")
            filter_table = ask("Filter table name (or press Enter to skip)")
            if not filter_table:
                return {"enabled": False}
            filter_column = ask("Filter column name")

    # --- Description ---
    default_desc = (
        f"Each user sees data filtered to their assigned "
        f"{filter_table}.{filter_column} values."
    )
    if auto:
        description = default_desc
    else:
        description = ask(
            "Description for LLM context (Enter for default)", default_desc
        )

    return {
        "enabled": True,
        "identity_table": identity_table,
        "identity_column": identity_column,
        "filter_table": filter_table,
        "filter_column": filter_column,
        "custom_lookup_dax": None,
        "description": description,
    }


# ---------------------------------------------------------------------------
# File writing
# ---------------------------------------------------------------------------

def confirm_overwrite(path: pathlib.Path, auto: bool) -> bool:
    """Check if file exists and confirm overwrite."""
    if not path.exists():
        return True
    if auto:
        return True
    raw = input(f"  {path.name} already exists. Overwrite? [y/N]: ").strip()
    return raw.lower() in ("y", "yes")


def write_schema(schema: dict[str, Any], auto: bool) -> bool:
    """Write schema.json."""
    if not confirm_overwrite(SCHEMA_PATH, auto):
        info("Skipping schema.json")
        return False
    SCHEMA_PATH.parent.mkdir(parents=True, exist_ok=True)
    SCHEMA_PATH.write_text(json.dumps(schema, indent=2) + "\n")
    ok(f"Written to {SCHEMA_PATH.relative_to(ROOT)}")
    return True


def write_rls_config(rls: dict[str, Any], auto: bool) -> bool:
    """Write rls_config.json."""
    if not confirm_overwrite(RLS_PATH, auto):
        info("Skipping rls_config.json")
        return False
    RLS_PATH.write_text(json.dumps(rls, indent=2) + "\n")
    ok(f"Written to {RLS_PATH.relative_to(ROOT)}")
    return True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Auto-discover dataset schema & RLS configuration"
    )
    parser.add_argument(
        "--auto", action="store_true",
        help="Non-interactive mode — accept all defaults",
    )
    args = parser.parse_args()
    auto: bool = args.auto

    # Banner
    print()
    print(f"{BOLD}🔧  Power BI RLS Chatbot — First-Time Setup{END}")
    print("=" * 48)

    # 1. Environment
    env = load_env()

    # 2. Tokens
    tokens = acquire_tokens(env)

    workspace = env["PBI_WORKSPACE_ID"]
    dataset = env["PBI_DATASET_ID"]

    # 3. Schema discovery
    step(1, 3, "Dataset Schema")
    schema = discover_schema_dax(tokens["dax"], workspace, dataset)
    if not schema or not schema.get("tables"):
        fail("Could not discover schema. Check DAX token and dataset access.")
        sys.exit(1)

    n_tables = len(schema["tables"])
    n_cols = sum(len(t["columns"]) for t in schema["tables"])
    n_msr = sum(len(t["measures"]) for t in schema["tables"])
    ok(f"Discovered {n_tables} tables, {n_cols} columns, {n_msr} measures")
    write_schema(schema, auto)

    # 4. RLS detection
    step(2, 3, "Model Analysis")
    tmdl_info: dict[str, Any] | None = None

    # Try Fabric API for TMDL (roles + relationships)
    fabric_token = tokens.get("sp_fabric") or tokens.get("sp_pbi")
    if fabric_token:
        info("Fetching model definition via Fabric API…")
        tmdl_files = fetch_tmdl(fabric_token, workspace, dataset)
        if tmdl_files:
            ok(f"Retrieved {len(tmdl_files)} TMDL files")
            tmdl_info = detect_rls_from_tmdl(tmdl_files)
            if tmdl_info:
                ok("RLS role detected from model definition")
            else:
                info("No RLS roles found in TMDL — using heuristics")
        else:
            info("TMDL not available — using schema heuristics")
    else:
        info("No Fabric token — using schema heuristics")

    # Heuristic detection (always compute as fallback/supplement)
    heuristic = detect_rls_heuristic(schema)
    if heuristic.get("identity_candidates"):
        info(
            f"Heuristic candidates: "
            + ", ".join(
                f"{t}[{c}]"
                for t, c in heuristic["identity_candidates"][:3]
            )
        )

    # 5. Configure RLS
    step(3, 3, "RLS Configuration")
    rls = configure_rls_interactive(schema, tmdl_info, heuristic, auto)
    write_rls_config(rls, auto)

    # 6. Summary
    print(f"\n{BOLD}{'=' * 48}{END}")
    if rls.get("enabled"):
        print(f"{GREEN}✅ Setup complete!{END}")
        print(f"   Identity:  {rls['identity_table']}[{rls['identity_column']}]")
        print(f"   Filter:    {rls['filter_table']}[{rls['filter_column']}]")
    else:
        print(f"{YELLOW}⚠  Setup complete (RLS disabled in chat){END}")
        print("   The embedded report still enforces RLS via embed tokens.")

    print(f"\n   Run: {BOLD}uvicorn app:app --reload --port 8000{END}")
    print()


if __name__ == "__main__":
    main()
