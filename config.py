"""
Power BI RLS Chatbot — Application settings loaded from .env
"""

from __future__ import annotations

import json
from pydantic_settings import BaseSettings
from pydantic import field_validator


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

    # Azure OpenAI
    azure_openai_endpoint: str
    azure_openai_api_key: str
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
