"""
Power BI RLS Chatbot — FastAPI application
Embeds a Power BI report with RLS + a side-by-side chatbot.
"""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel

from chat_engine import chat
from config import settings
from powerbi_service import generate_embed_token

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Power BI RLS Chatbot starting …")
    yield
    logger.info("Shutting down …")


app = FastAPI(title="Power BI RLS Chatbot", lifespan=lifespan)
app.mount("/static", StaticFiles(directory="static"), name="static")
templates = Jinja2Templates(directory="templates")


# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "demo_users": settings.demo_users,
        },
    )


# ---------------------------------------------------------------------------
# API — Embed Token
# ---------------------------------------------------------------------------


class EmbedRequest(BaseModel):
    rls_username: str


@app.post("/api/embed-token")
async def api_embed_token(body: EmbedRequest):
    """Return an embed token scoped with effective identity for RLS."""
    data = await generate_embed_token(rls_username=body.rls_username)
    return data


# ---------------------------------------------------------------------------
# API — Chat
# ---------------------------------------------------------------------------


class ChatRequest(BaseModel):
    message: str
    rls_username: str
    history: list[dict[str, str]] = []


@app.post("/api/chat")
async def api_chat(body: ChatRequest):
    """Process a chat message, execute DAX with RLS, return answer."""
    result = await chat(
        user_message=body.message,
        rls_username=body.rls_username,
        conversation_history=body.history,
    )
    return result


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------


@app.get("/health")
async def health():
    return {"status": "ok"}
