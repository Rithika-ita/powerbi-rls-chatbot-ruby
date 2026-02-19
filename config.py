"""
Power BI RLS Chatbot — Application settings loaded from .env
"""

from __future__ import annotations

import json
import logging
import pathlib
from typing import Any

from pydantic_settings import BaseSettings
from pydantic import field_validator

logger = logging.getLogger(__name__)


class Settings(BaseSettings):
    # Azure AD / Entra ID
    azure_tenant_id: str
    azure_client_id: str
    azure_client_secret: str

    # Power BI
    pbi_workspace_id: str
    pbi_report_id: str
    pbi_dataset_id: str
    pbi_rls_role: str = "ViewerRole"

    # DAX execution auth mode: "azcli" (default) or "ropc"
    dax_auth_mode: str = "azcli"
    dax_user_email: str = ""
    dax_user_password: str = ""

    # Azure OpenAI
    azure_openai_endpoint: str
    azure_openai_api_key: str = ""
    azure_openai_deployment: str = "gpt-4o"
    azure_openai_api_version: str = "2024-12-01-preview"

    # App
    app_secret_key: str = "change-me"
    demo_users: dict[str, str] = {
        "Alice (West Region)": "alice@contoso.com",
        "Bob (East Region)": "bob@contoso.com",
        "Carlos (All Regions)": "carlos@contoso.com",
    }

    @field_validator("demo_users", mode="before")
    @classmethod
    def _parse_demo_users(cls, v):
        if isinstance(v, str):
            return json.loads(v)
        return v

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8"}


settings = Settings()  # type: ignore[call-arg]


# ---------------------------------------------------------------------------
# RLS configuration (loaded from rls_config.json)
# ---------------------------------------------------------------------------

_rls_config: dict[str, Any] | None = None


def get_rls_config() -> dict[str, Any]:
    """
    Load RLS configuration from rls_config.json.
    Returns a dict with keys:
      enabled, identity_table, identity_column,
      filter_table, filter_column, custom_lookup_dax, description
    Returns {"enabled": False} if the file is missing.
    """
    global _rls_config
    if _rls_config is not None:
        return _rls_config

    config_path = pathlib.Path(__file__).parent / "rls_config.json"
    if not config_path.exists():
        logger.warning(
            "rls_config.json not found — DAX queries will run WITHOUT RLS filtering. "
            "Copy rls_config.example.json → rls_config.json and customise it."
        )
        _rls_config = {"enabled": False}
        return _rls_config

    try:
        raw = json.loads(config_path.read_text())
        _rls_config = {
            "enabled": raw.get("enabled", True),
            "identity_table": raw.get("identity_table", ""),
            "identity_column": raw.get("identity_column", ""),
            "filter_table": raw.get("filter_table", ""),
            "filter_column": raw.get("filter_column", ""),
            "custom_lookup_dax": raw.get("custom_lookup_dax"),
            "description": raw.get("description", ""),
        }
        if _rls_config["enabled"]:
            logger.info(
                "RLS config loaded: filter on %s[%s] via %s[%s]",
                _rls_config["filter_table"],
                _rls_config["filter_column"],
                _rls_config["identity_table"],
                _rls_config["identity_column"],
            )
        return _rls_config
    except Exception as e:
        logger.error("Failed to parse rls_config.json: %s", e)
        _rls_config = {"enabled": False}
        return _rls_config
