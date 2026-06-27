"""Quota-aware routing for the LiteLLM proxy.

This plugin lets a LiteLLM proxy route each request to whichever AI subscription
still has budget, reading live headroom from a locally running quotabot. When
every metered subscription is low it falls back to a local runtime (Ollama, LM
Studio) so work keeps flowing for free instead of failing on a spent cap.

It plugs into two LiteLLM extension points (see https://docs.litellm.ai):

  - ``async_pre_call_hook``: rewrites ``data["model"]`` to the best deployment
    before the call is made, based on quotabot headroom and per-agent rules.
  - ``async_log_success_event``: appends a routing/usage record so quotabot can
    later report how much work each provider actually served.

Design goals, in priority order:

  1. Never break the proxy. Any failure (quotabot down, bad policy, network
     blip) falls through to the originally requested model. Routing is an
     optimization, not a dependency.
  2. Reuse quotabot's decision logic. Availability and headroom come from
     quotabot's ``/suggest`` endpoint, so the binding-window rules live in one
     place (the Dart collector) rather than being reimplemented here.
  3. Zero usage tokens to decide. quotabot reads only local metadata.

It is pure-stdlib apart from LiteLLM itself and PyYAML (already a LiteLLM
dependency), so it runs unchanged on Windows, macOS, and Linux.
"""

from __future__ import annotations

import asyncio
import ipaddress
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

try:  # LiteLLM is present when this runs inside the proxy.
    from litellm.integrations.custom_logger import CustomLogger
except Exception:  # pragma: no cover - allows importing/testing without litellm.
    class CustomLogger:  # type: ignore
        """Minimal stand-in so the module imports without LiteLLM installed."""


def _expand(path: str) -> Path:
    return Path(os.path.expanduser(os.path.expandvars(path)))


def _is_loopback_url(url: str) -> bool:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        return False
    host = parsed.hostname
    if not host:
        return False
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


@dataclass(frozen=True)
class Candidate:
    """One deployment a logical model may route to.

    ``deployment`` is a ``model_name`` defined in the LiteLLM proxy config.
    ``provider`` is the quotabot provider id whose headroom gates this candidate
    (codex, claude, grok, antigravity, ...). ``local`` marks an always-available
    local runtime that is never gated by headroom.
    """

    deployment: str
    provider: Optional[str] = None
    local: bool = False


@dataclass(frozen=True)
class AgentRule:
    """How to route a named agent. ``pin`` forces a concrete deployment and
    skips routing entirely; ``model`` redirects the agent to a logical model
    that is then routed normally."""

    pin: Optional[str] = None
    model: Optional[str] = None


@dataclass
class Policy:
    quotabot_url: str = "http://127.0.0.1:8721"
    snapshot_ttl_seconds: float = 45.0
    comfort_threshold: float = 15.0
    metrics_path: Optional[str] = None
    models: dict[str, list[Candidate]] = field(default_factory=dict)
    agents: dict[str, AgentRule] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not _is_loopback_url(self.quotabot_url):
            self.quotabot_url = "http://127.0.0.1:8721"
        self.snapshot_ttl_seconds = max(1.0, min(float(self.snapshot_ttl_seconds), 3600.0))
        self.comfort_threshold = max(0.0, min(float(self.comfort_threshold), 100.0))

    @classmethod
    def load(cls, path: Path) -> "Policy":
        import yaml  # Local import: only needed when a policy file is used.

        raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        models: dict[str, list[Candidate]] = {}
        for name, spec in (raw.get("models") or {}).items():
            cands = []
            for c in spec.get("candidates", []):
                cands.append(
                    Candidate(
                        deployment=c["deployment"],
                        provider=c.get("provider"),
                        local=bool(c.get("local", False)),
                    )
                )
            models[name] = cands
        agents = {
            name: AgentRule(pin=rule.get("pin"), model=rule.get("model"))
            for name, rule in (raw.get("agents") or {}).items()
        }
        return cls(
            quotabot_url=raw.get("quotabot_url", cls.quotabot_url),
            snapshot_ttl_seconds=float(
                raw.get("snapshot_ttl_seconds", cls.snapshot_ttl_seconds)
            ),
            comfort_threshold=float(
                raw.get("comfort_threshold", cls.comfort_threshold)
            ),
            metrics_path=raw.get("metrics_path"),
            models=models,
            agents=agents,
        )


class QuotabotRouter(CustomLogger):
    """LiteLLM logger/hook that routes by live quota headroom.

    Register it in the proxy config (config.yaml)::

        litellm_settings:
          callbacks: quotabot_router.proxy_handler_instance

    The policy file location defaults to ``quotabot-routing.yaml`` next to this
    module and can be overridden with the ``QUOTABOT_ROUTING`` env var.
    """

    def __init__(self, policy_path: Optional[str] = None) -> None:
        path = _expand(
            policy_path
            or os.environ.get("QUOTABOT_ROUTING")
            or str(Path(__file__).with_name("quotabot-routing.yaml"))
        )
        try:
            self.policy = Policy.load(path) if path.exists() else Policy()
        except Exception:
            # A broken policy must not take the proxy down; route nothing.
            self.policy = Policy()
        # Cached availability map: provider id -> candidate dict from /suggest.
        self._cache: dict[str, dict[str, Any]] = {}
        self._cache_at: float = 0.0
        self._lock = asyncio.Lock()

    # -- routing ------------------------------------------------------------

    async def async_pre_call_hook(
        self,
        user_api_key_dict: Any,
        cache: Any,
        data: dict,
        call_type: str,
    ) -> Optional[dict]:
        try:
            requested = data.get("model")
            chosen = await self._route(requested, data, user_api_key_dict)
            if chosen and chosen != requested:
                data.setdefault("metadata", {})["quotabot_original_model"] = requested
                data["model"] = chosen
        except Exception:
            # Fail soft: leave the request exactly as it was.
            pass
        return data

    async def _route(
        self, requested: Optional[str], data: dict, key: Any
    ) -> Optional[str]:
        agent = self._agent_id(data, key)
        rule = self.policy.agents.get(agent) if agent else None

        # An agent pinned to a concrete deployment skips headroom routing.
        if rule and rule.pin:
            return rule.pin

        # An agent may redirect to a different logical model, then route it.
        logical = (rule.model if rule and rule.model else requested) or ""
        candidates = self.policy.models.get(logical)
        if not candidates:
            return requested  # not a managed model; pass through unchanged

        avail = await self._availability()
        if avail is None:
            return requested  # quotabot unreachable; pass through

        # First pass: honor the comfort threshold. Second pass: accept any
        # provider with a sliver left. Preference order is the policy order.
        # A local candidate wins exactly where the policy places it, so a
        # local-first logical model stays local while frontier models can keep
        # local candidates last as the fallback.
        for floor in (self.policy.comfort_threshold, 0.5):
            for c in candidates:
                if c.local:
                    return c.deployment
                info = avail.get(c.provider or "")
                if info and info.get("available") and _headroom(info) >= floor:
                    return c.deployment
        return requested

    @staticmethod
    def _agent_id(data: dict, key: Any) -> Optional[str]:
        """Best-effort identity for per-agent rules.

        Prefer LiteLLM key identity when present. Request metadata is
        client-controlled in many proxy setups and is only a fallback for local
        trusted clients that do not use key aliases.
        """
        for attr in ("key_alias", "user_id"):
            value = getattr(key, attr, None)
            if isinstance(value, str) and value:
                return value
        meta = data.get("metadata") or {}
        for field_name in ("agent", "agent_id", "user"):
            value = meta.get(field_name)
            if isinstance(value, str) and value:
                return value
        return None

    # -- quotabot snapshot --------------------------------------------------

    async def _availability(self) -> Optional[dict[str, dict[str, Any]]]:
        """Returns ``{provider_id: candidate_info}`` from quotabot's /suggest,
        cached for ``snapshot_ttl_seconds``. None when quotabot is unreachable."""
        async with self._lock:
            if self._cache and (time.monotonic() - self._cache_at) < self.policy.snapshot_ttl_seconds:
                return self._cache
            payload = await asyncio.to_thread(self._fetch_suggest)
            if payload is None:
                return None
            ranked = payload.get("ranked") or []
            self._cache = {c["provider"]: c for c in ranked if "provider" in c}
            self._cache_at = time.monotonic()
            return self._cache

    def _fetch_suggest(self) -> Optional[dict]:
        if not _is_loopback_url(self.policy.quotabot_url):
            return None
        url = self.policy.quotabot_url.rstrip("/") + "/suggest"
        try:
            with urllib.request.urlopen(url, timeout=2) as resp:  # noqa: S310 (local only)
                return json.loads(resp.read().decode("utf-8"))
        except (urllib.error.URLError, OSError, ValueError):
            return None

    # -- metrics ------------------------------------------------------------

    async def async_log_success_event(
        self, kwargs: dict, response_obj: Any, start_time: Any, end_time: Any
    ) -> None:
        if not self.policy.metrics_path:
            return
        try:
            meta = (kwargs.get("litellm_params") or {}).get("metadata") or {}
            usage = getattr(response_obj, "usage", None)
            record = {
                "at": int(time.time()),
                "requested_model": meta.get("quotabot_original_model"),
                "served_model": kwargs.get("model"),
                "prompt_tokens": getattr(usage, "prompt_tokens", None),
                "completion_tokens": getattr(usage, "completion_tokens", None),
                "cost": kwargs.get("response_cost"),
            }
            await asyncio.to_thread(self._append_metric, record)
        except Exception:
            pass

    def _append_metric(self, record: dict) -> None:
        path = _expand(self.policy.metrics_path)  # type: ignore[arg-type]
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\n")


def _headroom(info: dict[str, Any]) -> float:
    value = info.get("headroom_percent")
    return float(value) if isinstance(value, (int, float)) else 0.0


# The proxy references this instance by attribute path in config.yaml.
proxy_handler_instance = QuotabotRouter()
