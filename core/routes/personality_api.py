from __future__ import annotations

import asyncio
import json
import logging
import uuid
from typing import Any

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from core import app_state

router = APIRouter()
_LOGGER = logging.getLogger(__name__)
_PENDING_TURNS: dict[str, str] = {}
_PENDING_LOCK = asyncio.Lock()
_MAX_MESSAGE_CHARS = 20000
_MAX_TOOL_CALLS = 100


class PrepareRequest(BaseModel):
    user_message: str = Field(min_length=1, max_length=_MAX_MESSAGE_CHARS)


class CommitRequest(BaseModel):
    turn_id: str = Field(min_length=1, max_length=128)
    assistant_message: str = Field(min_length=1, max_length=_MAX_MESSAGE_CHARS)
    tool_calls: list[dict[str, Any]] = Field(default_factory=list, max_length=_MAX_TOOL_CALLS)


def _require_loopback(request: Request) -> None:
    host = request.client.host if request.client else None
    if host not in {"127.0.0.1", "::1"}:
        raise HTTPException(status_code=403, detail="local access required")


def _agent_or_error():
    agent = app_state.global_agent
    if agent is None or getattr(agent, "context", None) is None:
        raise HTTPException(status_code=503, detail="Crescent agent is not ready")
    return agent


def _build_runtime_state(agent) -> str:
    context = agent.context
    parts: list[str] = []
    vital_manager = getattr(agent, "vital_manager", None)
    if vital_manager:
        vital_prompt = vital_manager.get_vital_prompt()
        if vital_prompt:
            parts.append(vital_prompt.strip())
        parts.append(
            "Crescent vitality state:\n"
            + json.dumps(vital_manager.get_status(), ensure_ascii=False)
        )
        desire_manager = getattr(vital_manager, "desire_manager", None)
        if desire_manager:
            parts.append(
                "Crescent desire state:\n"
                + json.dumps(desire_manager.get_status(), ensure_ascii=False)
            )
        moontide = getattr(vital_manager, "moontide", None)
        if moontide:
            parts.append(
                "Crescent MoonTide state:\n"
                + json.dumps(moontide.get_state_snapshot(), ensure_ascii=False)
            )
    summary = context._build_summary_content()
    if summary:
        parts.append(summary.strip())
    messages = context.build_messages()
    for index, message in enumerate(messages):
        if index == 0 or message.get("role") != "system":
            continue
        content = message.get("content")
        if not isinstance(content, str) or not content.strip():
            continue
        if content == getattr(context, "system_memories", ""):
            continue
        if content == getattr(context, "system_bottom", ""):
            continue
        if content == summary:
            continue
        parts.append(content.strip())
    return "\n\n".join(parts)


@router.post("/api/personality/prepare")
async def prepare(request: Request, payload: PrepareRequest):
    _require_loopback(request)
    agent = _agent_or_error()
    async with app_state.global_processing_lock.lock:
        try:
            if agent.vital_manager:
                agent.vital_manager.update_stamina()
                agent.context._pending_vital_prompt = agent.vital_manager.get_vital_prompt()
            else:
                agent.context._pending_vital_prompt = ""
            agent.context.add_user_message(payload.user_message)
            state = _build_runtime_state(agent)
            turn_id = uuid.uuid4().hex
            async with _PENDING_LOCK:
                _PENDING_TURNS[turn_id] = payload.user_message
            return {"turn_id": turn_id, "state": state}
        except HTTPException:
            raise
        except Exception as exc:
            _LOGGER.exception("personality prepare failed")
            raise HTTPException(status_code=500, detail="personality preparation failed") from exc


@router.post("/api/personality/commit")
async def commit(request: Request, payload: CommitRequest):
    _require_loopback(request)
    agent = _agent_or_error()
    async with _PENDING_LOCK:
        user_message = _PENDING_TURNS.pop(payload.turn_id, None)
    if user_message is None:
        raise HTTPException(status_code=409, detail="unknown or completed turn")
    async with app_state.global_processing_lock.lock:
        try:
            agent.context.add_assistant_message(payload.assistant_message)
            agent.context.save_state()
            if agent.salia:
                asyncio.create_task(
                    agent.salia.evaluate_turn(
                        user_message=user_message,
                        assistant_message=payload.assistant_message,
                        tool_calls_summary=payload.tool_calls,
                        rag_db=getattr(agent, "rag_db", None),
                        desire_manager=getattr(agent.vital_manager, "desire_manager", None)
                        if agent.vital_manager
                        else None,
                        moontide=getattr(agent.vital_manager, "moontide", None)
                        if agent.vital_manager
                        else None,
                    )
                )
            return {"accepted": True}
        except HTTPException:
            raise
        except Exception as exc:
            _LOGGER.exception("personality commit failed")
            raise HTTPException(status_code=500, detail="personality commit failed") from exc
