"""
Thin LLM provider facade (PRD §9.1).

Captain talks to an LLM from many places: chat, profile rewrites, calendar
extraction, radar suggestions, hunt document extraction, scope gate, the
first-session feature extractor, and the renderer. The PRD requires that
the underlying provider be swappable without rewriting every callsite.

This module gives every caller the same entry point — `chat_completion(...)`
— and lets the provider be selected per env var. Today only OpenAI is
wired (`CAPTAIN_LLM_PROVIDER=openai`, the default). Adding Anthropic later
is a matter of teaching `chat_completion` how to translate the OpenAI-
shaped arguments into Anthropic's `messages.create(...)` shape and
returning a `LLMResponse` with the same fields. No callsite churn.

Why the OpenAI shape stays the canonical surface (rather than something
neutral): every callsite was already written against it; vision payloads
are already encoded as `{"type": "image_url", "image_url": {"url": ...}}`;
JSON-schema response_format is OpenAI-flavored. A neutral surface would
mean rewriting all of that for one v1 provider, which the PRD calls out
as exactly the wrong tradeoff.

Returned `LLMResponse` carries:
  - `text`: the assistant's text content (may be empty if a tool was called)
  - `tool_calls`: list of OpenAI-shaped tool-call objects (may be empty)
  - `raw`: the underlying SDK message object — for callers that still
    need provider-specific fields (e.g. chat.py's tool-call loop).

Observability: each call prints a one-line summary on completion
(`[llm] model=… ok elapsed=…s`) so cost / latency tracking can be
sampled from logs without external infra.
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass, field
from typing import Any

from openai import OpenAI

# Module-level OpenAI client — instantiating it is cheap, but reusing
# one connection pool across the process is cheaper than rebuilding the
# client on every call. None until first use (so importing this module
# never requires an API key being set).
_openai_client: OpenAI | None = None


def _get_openai() -> OpenAI:
    global _openai_client
    if _openai_client is None:
        _openai_client = OpenAI()
    return _openai_client


def provider() -> str:
    """The currently-selected provider name. `openai` is the only one
    wired in v1; the env var is reserved for the multi-provider
    migration."""
    return os.getenv("CAPTAIN_LLM_PROVIDER", "openai").lower()


@dataclass
class LLMResponse:
    text: str
    tool_calls: list[Any] = field(default_factory=list)
    raw: Any = None


def chat_completion(
    *,
    model: str,
    messages: list[dict],
    tools: list[dict] | None = None,
    response_format: dict | None = None,
    temperature: float | None = None,
) -> LLMResponse:
    """One-shot chat completion. Provider-agnostic surface; today routes
    to OpenAI. All arguments are in the OpenAI SDK's shape (messages
    with `role`/`content`, tools as `{"type":"function", ...}`,
    response_format with `{"type":"json_schema", ...}`).

    Raises whatever the underlying SDK raises — callers handle their
    own retry / fallback policies. The seam is *which provider* to
    route to, not error semantics.
    """
    started = time.time()
    prov = provider()
    if prov != "openai":
        # Reserved for the multi-provider rollout. Failing loud here is
        # better than silently routing to OpenAI when the operator
        # asked for something else.
        raise NotImplementedError(
            f"CAPTAIN_LLM_PROVIDER={prov!r} is not wired yet; only "
            f"'openai' works in v1."
        )

    client = _get_openai()
    kwargs: dict[str, Any] = {"model": model, "messages": messages}
    if tools is not None:
        kwargs["tools"] = tools
    if response_format is not None:
        kwargs["response_format"] = response_format
    if temperature is not None:
        kwargs["temperature"] = temperature

    try:
        resp = client.chat.completions.create(**kwargs)
    except Exception as e:  # noqa: BLE001
        elapsed = time.time() - started
        print(f"[llm] model={model} provider={prov} ERROR "
              f"elapsed={elapsed:.2f}s: {type(e).__name__}")
        raise

    choice = resp.choices[0].message
    tool_calls = list(getattr(choice, "tool_calls", None) or [])
    text = choice.content or ""

    elapsed = time.time() - started
    print(f"[llm] model={model} provider={prov} ok "
          f"elapsed={elapsed:.2f}s "
          f"tool_calls={len(tool_calls)} chars={len(text)}")

    return LLMResponse(text=text, tool_calls=tool_calls, raw=choice)
