"""
Chat orchestrator — takes natural language, generates DAX, executes with RLS,
and returns a natural-language answer.
"""

from __future__ import annotations

import json
import logging
import re
from typing import Any

from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from openai import AsyncAzureOpenAI

from config import settings, get_rls_config
from powerbi_service import execute_dax, get_dataset_schema, get_user_filter_values, get_dax_token

logger = logging.getLogger(__name__)

_client: AsyncAzureOpenAI | None = None


def _get_openai_client() -> AsyncAzureOpenAI:
    global _client
    if _client is None:
        credential = DefaultAzureCredential()
        token_provider = get_bearer_token_provider(
            credential, "https://cognitiveservices.azure.com/.default"
        )
        _client = AsyncAzureOpenAI(
            azure_endpoint=settings.azure_openai_endpoint,
            azure_ad_token_provider=token_provider,
            api_version=settings.azure_openai_api_version,
        )
    return _client


# ---------------------------------------------------------------------------
# System prompt — built dynamically from schema + RLS config
# ---------------------------------------------------------------------------

SYSTEM_PROMPT_BASE = """\
You are a helpful data analyst chatbot. You answer questions about business data
stored in a Power BI semantic model (dataset).

## Dataset Schema
{schema_json}

{rls_context}

## Rules
1. When the user asks a data question, generate a **single valid DAX query**
   wrapped in a ```dax code fence.
2. Use EVALUATE to return a table result.  Do NOT use DEFINE unless needed for
   variables.
3. Only reference tables, columns, and measures from the schema above.
4. {rls_filter_rule}
5. If the user asks something unrelated to the data, respond conversationally
   WITHOUT generating DAX.
6. Keep DAX concise and correct.  Prefer SUMMARIZECOLUMNS for aggregations.
7. After receiving the query results, provide a clear, concise natural-language
   answer.  If the results are tabular, format them as a Markdown table.
8. If a query returns no data, say so and suggest the user may not have access
   to that slice of data due to their role.
"""


def _build_system_prompt(
    schema_json: str,
    rls_username: str,
    user_filter_values: list[str],
) -> str:
    """Build the system prompt dynamically based on RLS config."""
    rls = get_rls_config()

    if rls.get("enabled") and user_filter_values:
        ft = rls["filter_table"]
        fc = rls["filter_column"]
        desc = rls.get("description", "")
        values_str = ", ".join(user_filter_values)
        rls_context = (
            f"## Current User RLS Context\n"
            f"The current user ({rls_username}) has access to these "
            f"{ft}.{fc} values: {values_str}\n"
            f"All DAX query results will be automatically filtered to these values.\n"
            f"{desc}"
        )
        rls_filter_rule = (
            f"Do NOT add {ft}/{fc} filters yourself — the system "
            f"automatically applies RLS filters via CALCULATETABLE + TREATAS."
        )
    elif rls.get("enabled"):
        rls_context = (
            f"## Current User RLS Context\n"
            f"The current user ({rls_username}) has no accessible data in this model."
        )
        rls_filter_rule = "The user has no data access. Inform them politely."
    else:
        rls_context = "## Note\nNo Row-Level Security is configured for this dataset."
        rls_filter_rule = "No RLS filters are applied. Queries return all data."

    return SYSTEM_PROMPT_BASE.format(
        schema_json=schema_json,
        rls_context=rls_context,
        rls_filter_rule=rls_filter_rule,
    )


def _extract_dax(text: str) -> str | None:
    """Extract a DAX query from a ```dax code fence."""
    m = re.search(r"```dax\s*\n(.*?)```", text, re.DOTALL | re.IGNORECASE)
    if m:
        return m.group(1).strip()
    # Fallback: look for EVALUATE anywhere
    m = re.search(r"(EVALUATE\b.+)", text, re.DOTALL | re.IGNORECASE)
    if m:
        return m.group(1).strip()
    return None


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def chat(
    user_message: str,
    rls_username: str,
    conversation_history: list[dict[str, str]] | None = None,
) -> dict[str, Any]:
    """
    Process a chat message:
      1. Send conversation + schema to LLM
      2. If LLM generates DAX → execute with RLS
      3. Feed results back to LLM for summarisation
      4. Return final answer + optional DAX + raw data
    """
    client = _get_openai_client()

    # Build schema context
    schema = await get_dataset_schema()

    # Get user's allowed filter values for the system prompt
    rls = get_rls_config()
    user_filter_values: list[str] = []
    if rls.get("enabled"):
        token = get_dax_token()
        user_filter_values = await get_user_filter_values(rls_username, token)

    system_msg = _build_system_prompt(
        schema_json=json.dumps(schema, indent=2),
        rls_username=rls_username,
        user_filter_values=user_filter_values,
    )

    messages: list[dict[str, str]] = [{"role": "system", "content": system_msg}]
    if conversation_history:
        messages.extend(conversation_history[-10:])
    messages.append({"role": "user", "content": user_message})

    # --- Step 1: Ask LLM to generate DAX (or conversational reply) -----------
    resp1 = await client.chat.completions.create(
        model=settings.azure_openai_deployment,
        messages=messages,
        temperature=0.1,
        max_tokens=1024,
    )
    assistant_text = resp1.choices[0].message.content or ""

    dax_query = _extract_dax(assistant_text)

    if dax_query is None:
        return {
            "answer": assistant_text,
            "dax": None,
            "data": None,
        }

    # --- Step 2: Execute DAX with RLS impersonation --------------------------
    try:
        rows = await execute_dax(dax_query, rls_username)
    except Exception as exc:
        logger.exception("DAX execution failed")
        return {
            "answer": f"I generated a query but it failed to execute: {exc}",
            "dax": dax_query,
            "data": None,
        }

    # --- Step 3: Summarise results -------------------------------------------
    result_text = json.dumps(rows[:200], indent=2)
    messages.append({"role": "assistant", "content": assistant_text})
    messages.append({
        "role": "user",
        "content": (
            f"Here are the query results (JSON). Summarise them in natural language "
            f"for the user. If tabular, show a Markdown table.\n\n{result_text}"
        ),
    })

    resp2 = await client.chat.completions.create(
        model=settings.azure_openai_deployment,
        messages=messages,
        temperature=0.3,
        max_tokens=1024,
    )
    final_answer = resp2.choices[0].message.content or ""

    return {
        "answer": final_answer,
        "dax": dax_query,
        "data": rows[:50],
    }
