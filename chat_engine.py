"""
Chat orchestrator — takes natural language, generates DAX, executes with RLS,
and returns a natural-language answer.
"""

from __future__ import annotations

import json
import logging
import re
from typing import Any

from openai import AsyncAzureOpenAI

from config import settings
from powerbi_service import execute_dax, get_dataset_schema

logger = logging.getLogger(__name__)

_client: AsyncAzureOpenAI | None = None


def _get_openai_client() -> AsyncAzureOpenAI:
    global _client
    if _client is None:
        _client = AsyncAzureOpenAI(
            azure_endpoint=settings.azure_openai_endpoint,
            api_key=settings.azure_openai_api_key,
            api_version=settings.azure_openai_api_version,
        )
    return _client


# ---------------------------------------------------------------------------
# System prompt template
# ---------------------------------------------------------------------------

SYSTEM_PROMPT_TEMPLATE = """\
You are a helpful data analyst chatbot. You answer questions about business data
stored in a Power BI semantic model (dataset).

## Dataset Schema
{schema_json}

## Rules
1. When the user asks a data question, generate a **single valid DAX query**
   wrapped in a ```dax code fence.
2. Use EVALUATE to return a table result.  Do NOT use DEFINE unless needed for
   variables.
3. Only reference tables, columns, and measures from the schema above.
4. Never use CALCULATE with filters that would bypass Row-Level Security.
5. If the user asks something unrelated to the data, respond conversationally
   WITHOUT generating DAX.
6. Keep DAX concise and correct.  Prefer SUMMARIZECOLUMNS for aggregations.
7. After receiving the query results, provide a clear, concise natural-language
   answer.  If the results are tabular, format them as a Markdown table.
8. If a query returns no data, say so and suggest the user may not have access
   to that slice of data.
"""


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
      2. If LLM generates DAX → execute with RLS effective identity
      3. Feed results back to LLM for summarisation
      4. Return final answer + optional DAX + raw data
    """
    client = _get_openai_client()

    # Build schema context
    schema = await get_dataset_schema()
    system_msg = SYSTEM_PROMPT_TEMPLATE.format(schema_json=json.dumps(schema, indent=2))

    messages: list[dict[str, str]] = [{"role": "system", "content": system_msg}]
    if conversation_history:
        messages.extend(conversation_history[-10:])  # keep last 10 turns
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
        # No DAX → purely conversational
        return {
            "answer": assistant_text,
            "dax": None,
            "data": None,
        }

    # --- Step 2: Execute DAX with effective identity -------------------------
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
    result_text = json.dumps(rows[:200], indent=2)  # cap at 200 rows
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
        "data": rows[:50],  # send first 50 rows to frontend
    }
