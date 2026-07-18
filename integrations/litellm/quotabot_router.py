"""Quota-aware routing for the LiteLLM proxy.

This plugin lets a LiteLLM proxy route each request to whichever AI subscription
still has budget, reading live headroom from a locally running quotabot. When
every metered subscription is low it can try a configured local-runtime
deployment. That request still depends on the backend being reachable and known
to execute locally; the plugin does not prove either property on its own.

It plugs into two LiteLLM extension points (see https://docs.litellm.ai):

  - ``async_pre_call_hook``: rewrites ``data["model"]`` to the best deployment
    before the call is made, based on quotabot headroom and per-agent rules.
  - ``async_log_success_event``: appends a routing/usage record so quotabot can
    later report how much work each provider actually served.

Design goals, in priority order:

  1. Avoid surprise paid API spend. Managed logical models fail closed when no
     allowed quota-plan or local route exists, while unmanaged model names still
     pass through unchanged.
  2. Reuse quotabot's decision logic. Availability and headroom come from
     quotabot's ``/suggest`` endpoint, so the binding-window rules live in one
     place (the Dart collector) rather than being reimplemented here. If
     quotabot is unavailable, a configured local candidate can be attempted as
     a fail-soft fallback, with reachability left to LiteLLM's backend call.
  3. Zero usage tokens to decide. quotabot may read local or provider metadata,
     but it makes no inference request and never receives the task content.

It is pure-stdlib apart from LiteLLM itself and PyYAML (already a LiteLLM
dependency), so it runs unchanged on Windows, macOS, and Linux.
"""

from __future__ import annotations

import asyncio
import csv
import datetime
import email.utils
import ipaddress
import json
import math
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Optional

try:  # LiteLLM is present when this runs inside the proxy.
    from litellm.integrations.custom_logger import CustomLogger
except Exception:  # pragma: no cover - allows importing/testing without litellm.
    class CustomLogger:  # type: ignore
        """Minimal stand-in so the module imports without LiteLLM installed."""


def _expand(path: str) -> Path:
    return Path(os.path.expanduser(os.path.expandvars(path)))


def _default_metrics_dir() -> Path:
    return Path.home() / ".quotabot"


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


def _safe_metrics_path(raw: Optional[str]) -> Optional[str]:
    if not raw:
        return None
    try:
        base = _default_metrics_dir().resolve()
        path = _expand(raw)
        if not path.is_absolute():
            path = base / path
        path = path.resolve(strict=False)
        path.relative_to(base)
        return str(path)
    except Exception:
        return None


def _windows_acl_principal() -> Optional[str]:
    try:
        result = subprocess.run(
            ["whoami", "/user", "/fo", "csv"],
            check=False,
            capture_output=True,
            text=True,
        )
    except Exception:
        return None
    if result.returncode != 0:
        return None
    for row in csv.reader(result.stdout.splitlines()):
        if len(row) >= 2 and row[1].startswith("S-1-"):
            return f"*{row[1]}"
    return None


def _restrict_owner_only_file(path: Path) -> None:
    try:
        if os.name == "nt":
            principal = _windows_acl_principal()
            if not principal:
                return
            subprocess.run(
                ["icacls", str(path), "/inheritance:r"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            subprocess.run(
                ["icacls", str(path), "/grant:r", f"{principal}:F"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        else:
            path.chmod(0o600)
    except Exception:
        return


def _restrict_owner_only_directory(path: Path) -> None:
    try:
        path.mkdir(parents=True, exist_ok=True)
        if os.name == "nt":
            principal = _windows_acl_principal()
            if not principal:
                return
            subprocess.run(
                ["icacls", str(path), "/inheritance:r"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            subprocess.run(
                ["icacls", str(path), "/grant:r", f"{principal}:(OI)(CI)F"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        else:
            path.chmod(0o700)
    except Exception:
        return


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        return None


_NO_REDIRECT_OPENER = urllib.request.build_opener(_NoRedirectHandler)
_SPEND_METADATA_KEY = "quotabot_spend"
_PROVIDER_METADATA_KEY = "quotabot_provider"
_ACCOUNT_METADATA_KEY = "quotabot_account"
_DECISION_METADATA_KEY = "quotabot_decision_id"


class _Availability(list[dict[str, Any]]):
    """Ranked candidates plus the receipt id from the same atomic response."""

    def __init__(
        self,
        entries: list[dict[str, Any]],
        decision_id: Optional[str],
    ) -> None:
        super().__init__(entries)
        self.decision_id = decision_id


class UnsafeRouteError(RuntimeError):
    """Raised when a managed logical model has no no-surprise-billing route."""


class Candidate:
    """One deployment a logical model may route to.

    ``deployment`` is a ``model_name`` defined in the LiteLLM proxy config.
    ``provider`` is the quotabot provider id whose headroom gates this candidate
    (codex, claude, grok, antigravity, ...). ``account`` optionally narrows that
    gate to one quotabot account for multi-account setups. ``local`` marks an
    configured local-runtime candidate that is not quota-gated. The router does
    not preflight its backend, so reachability is determined by the LiteLLM call.
    ``spend`` is a safety label: ``quota_plan`` means an included quota plan;
    ``overages_disabled`` is the separate proof bit that lets that plan route.
    ``paid_api`` means request-metered API spend that must be explicitly enabled.
    """

    __slots__ = (
        "deployment",
        "provider",
        "account",
        "local",
        "spend",
        "overages_disabled",
    )

    def __init__(
        self,
        deployment: str,
        provider: Optional[str] = None,
        account: Optional[str] = None,
        local: bool = False,
        spend: Optional[str] = None,
        overages_disabled: bool = False,
    ) -> None:
        self.deployment = deployment
        self.provider = _optional_text(provider)
        self.account = _optional_text(account)
        normalized_spend = "local" if local else _normalize_spend(spend)
        self.local = local or normalized_spend == "local"
        self.spend = "local" if self.local else normalized_spend
        self.overages_disabled = overages_disabled is True if not self.local else True


def _optional_text(value: Any) -> Optional[str]:
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def _normalize_spend(value: Optional[str]) -> str:
    normalized = (value or "paid_api").strip().lower().replace("-", "_")
    if normalized in {"quota", "quota_plan", "subscription", "subscription_quota"}:
        return "quota_plan"
    if normalized in {"local", "free"}:
        return "local"
    return "paid_api"


def _bool_value(value: Any, default: bool) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off"}:
            return False
    return default


def _overages_disabled_value(value: Any, overages: Any = None) -> bool:
    if value is not None:
        return _bool_value(value, False)
    if isinstance(overages, bool):
        return not overages
    if isinstance(overages, str):
        normalized = overages.strip().lower().replace("-", "_")
        return normalized in {"0", "false", "no", "off", "disabled", "none"}
    return False


class AgentRule:
    """How to route a named agent. ``pin`` forces a concrete deployment and
    skips headroom routing after spend-policy checks; ``model`` redirects the
    agent to a logical model that is then routed normally."""

    __slots__ = ("pin", "model", "pin_spend", "pin_overages_disabled")

    def __init__(
        self,
        pin: Optional[str] = None,
        model: Optional[str] = None,
        pin_spend: Optional[str] = None,
        pin_overages_disabled: bool = False,
    ) -> None:
        self.pin = pin
        self.model = model
        self.pin_spend = _normalize_spend(pin_spend) if pin else None
        self.pin_overages_disabled = pin_overages_disabled is True if pin else False


class Policy:
    default_quotabot_url = "http://127.0.0.1:8721"
    default_snapshot_ttl_seconds = 45.0
    default_comfort_threshold = 15.0
    default_allow_paid_api = False
    default_block_unsafe_passthrough = True

    def __init__(
        self,
        quotabot_url: str = default_quotabot_url,
        snapshot_ttl_seconds: float = default_snapshot_ttl_seconds,
        comfort_threshold: float = default_comfort_threshold,
        allow_paid_api: bool = default_allow_paid_api,
        block_unsafe_passthrough: bool = default_block_unsafe_passthrough,
        metrics_path: Optional[str] = None,
        models: Optional[dict[str, list[Candidate]]] = None,
        agents: Optional[dict[str, AgentRule]] = None,
    ) -> None:
        self.quotabot_url = quotabot_url
        self.snapshot_ttl_seconds = snapshot_ttl_seconds
        self.comfort_threshold = comfort_threshold
        self.allow_paid_api = _bool_value(allow_paid_api, self.default_allow_paid_api)
        self.block_unsafe_passthrough = _bool_value(
            block_unsafe_passthrough,
            self.default_block_unsafe_passthrough,
        )
        self.metrics_path = _safe_metrics_path(metrics_path)
        self.models = models or {}
        self.agents = agents or {}

        if not _is_loopback_url(self.quotabot_url):
            self.quotabot_url = self.default_quotabot_url
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
                        account=c.get("account"),
                        local=_bool_value(c.get("local"), False),
                        spend=c.get("spend"),
                        overages_disabled=_overages_disabled_value(
                            c.get("overages_disabled"),
                            c.get("overages"),
                        ),
                    )
                )
            models[name] = cands
        agents = {
            name: AgentRule(
                pin=rule.get("pin"),
                model=rule.get("model"),
                pin_spend=rule.get("pin_spend"),
                pin_overages_disabled=_overages_disabled_value(
                    rule.get("pin_overages_disabled"),
                    rule.get("pin_overages"),
                ),
            )
            for name, rule in (raw.get("agents") or {}).items()
        }
        return cls(
            quotabot_url=raw.get("quotabot_url", cls.default_quotabot_url),
            snapshot_ttl_seconds=float(
                raw.get("snapshot_ttl_seconds", cls.default_snapshot_ttl_seconds)
            ),
            comfort_threshold=float(
                raw.get("comfort_threshold", cls.default_comfort_threshold)
            ),
            allow_paid_api=_bool_value(
                raw.get("allow_paid_api"),
                cls.default_allow_paid_api,
            ),
            block_unsafe_passthrough=_bool_value(
                raw.get("block_unsafe_passthrough"),
                cls.default_block_unsafe_passthrough,
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
        # Cached ranked candidate dicts from /suggest.
        self._cache = _Availability([], None)
        # None until the first fetch. Freshness is tracked here, not by the
        # list's truthiness: a legitimately empty ranked list (e.g. only local
        # runtimes connected) must still be cached for the TTL, or every request
        # would trigger a fresh synchronous loopback fetch.
        self._cache_at: Optional[float] = None
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
        except UnsafeRouteError:
            raise
        except Exception:
            # Fail soft: leave the request exactly as it was.
            return data
        return data

    async def _route(
        self, requested: Optional[str], data: dict, key: Any
    ) -> Optional[str]:
        agent = self._agent_id(data, key)
        rule = self.policy.agents.get(agent) if agent else None

        # An agent pinned to a concrete deployment skips headroom routing, but
        # still must satisfy the spend policy.
        if rule and rule.pin:
            if self._spend_allowed(rule.pin_spend, rule.pin_overages_disabled):
                self._mark_route(data, spend=rule.pin_spend)
                return rule.pin
            return self._unsafe_passthrough(requested)

        # An agent may redirect to a different logical model, then route it.
        logical = (rule.model if rule and rule.model else requested) or ""
        candidates = self.policy.models.get(logical)
        if candidates is None:
            return requested  # not a managed model; pass through unchanged
        if not candidates:
            # Declared in the policy but with no candidate route. This is a
            # managed model, so it must fail closed rather than fall through to
            # the caller's original model and risk paid spend.
            return self._unsafe_passthrough(requested)

        allowed = [c for c in candidates if self._candidate_allowed(c)]
        if not allowed:
            return self._unsafe_passthrough(requested)

        avail = await self._availability()
        if avail is None:
            for c in allowed:
                if c.local:
                    self._mark_route(data, candidate=c)
                    return c.deployment
            return self._unsafe_passthrough(requested)

        ranked = _ranked_infos(avail)
        decision_id = _availability_decision_id(avail)
        local = next((c for c in allowed if c.local), None)
        if allowed[0].local:
            self._mark_route(
                data,
                candidate=allowed[0],
                decision_id=decision_id,
            )
            return allowed[0].deployment

        remote = _best_ranked_candidate(
            allowed,
            ranked,
            self.policy.comfort_threshold,
        )
        if remote:
            candidate, info = remote
            self._mark_route(
                data,
                candidate=candidate,
                info=_metric_info_for_candidate(info, ranked, candidate),
                decision_id=decision_id,
            )
            return candidate.deployment
        if local:
            self._mark_route(
                data,
                candidate=local,
                decision_id=decision_id,
            )
            return local.deployment

        remote = _best_ranked_candidate(allowed, ranked, 0.5)
        if remote:
            candidate, info = remote
            self._mark_route(
                data,
                candidate=candidate,
                info=_metric_info_for_candidate(info, ranked, candidate),
                decision_id=decision_id,
            )
            return candidate.deployment
        return self._unsafe_passthrough(requested)

    @staticmethod
    def _mark_route(
        data: dict,
        candidate: Optional[Candidate] = None,
        info: Optional[dict[str, Any]] = None,
        spend: Optional[str] = None,
        decision_id: Optional[str] = None,
    ) -> None:
        meta = data.setdefault("metadata", {})
        if spend is not None:
            route_spend = spend
        elif candidate:
            route_spend = candidate.spend
        else:
            route_spend = None
        if route_spend:
            meta[_SPEND_METADATA_KEY] = _normalize_spend(route_spend)
        provider = _string_field(info, "provider") or (
            candidate.provider if candidate else None
        )
        if provider:
            meta[_PROVIDER_METADATA_KEY] = provider
        account = candidate.account if candidate else None
        account = account or _string_field(info, "account")
        if account:
            meta[_ACCOUNT_METADATA_KEY] = account
        if _valid_decision_id(decision_id):
            meta[_DECISION_METADATA_KEY] = decision_id

    def _candidate_allowed(self, candidate: Candidate) -> bool:
        return candidate.local or self._spend_allowed(
            candidate.spend,
            candidate.overages_disabled,
        )

    def _spend_allowed(
        self,
        spend: Optional[str],
        overages_disabled: bool = False,
    ) -> bool:
        if spend == "local":
            return True
        if spend == "quota_plan":
            return overages_disabled
        return self.policy.allow_paid_api

    def _unsafe_passthrough(self, requested: Optional[str]) -> Optional[str]:
        if self.policy.block_unsafe_passthrough:
            raise UnsafeRouteError(
                f'quotabot has no safe no-surprise-billing route for "{requested}"'
            )
        return requested

    @staticmethod
    def _agent_id(data: dict, key: Any) -> Optional[str]:
        """Best-effort identity for per-agent rules.

        Only LiteLLM key identity is trusted for per-agent rules. Request
        metadata is client-controlled in many proxy setups, so it cannot select
        pinned or redirected deployments.
        """
        for attr in ("key_alias", "user_id"):
            value = getattr(key, attr, None)
            if isinstance(value, str) and value:
                return value
        return None

    # -- quotabot snapshot --------------------------------------------------

    async def _availability(self) -> Optional[list[dict[str, Any]]]:
        """Returns ranked candidate info from quotabot's /suggest, cached for
        ``snapshot_ttl_seconds``. None when quotabot is unreachable."""
        async with self._lock:
            if (
                self._cache_at is not None
                and (time.monotonic() - self._cache_at)
                < self.policy.snapshot_ttl_seconds
            ):
                return self._cache
            payload = await asyncio.to_thread(self._fetch_suggest)
            if payload is None:
                return None
            receipt = payload.get("receipt")
            versioned_receipt = (
                receipt
                if isinstance(receipt, dict)
                and receipt.get("schema") == "quotabot.receipt.v1"
                else None
            )
            candidate_id = _string_field(versioned_receipt, "decision_id")
            decision_id = candidate_id if _valid_decision_id(candidate_id) else None
            ranked = payload.get("ranked") or []
            self._cache = _Availability(
                [
                    c
                    for c in ranked
                    if isinstance(c, dict) and _string_field(c, "provider")
                ],
                decision_id,
            )
            self._cache_at = time.monotonic()
            return self._cache

    def _fetch_suggest(self) -> Optional[dict]:
        if not _is_loopback_url(self.policy.quotabot_url):
            return None
        url = self.policy.quotabot_url.rstrip("/") + "/suggest"
        try:
            with _NO_REDIRECT_OPENER.open(url, timeout=2) as resp:  # noqa: S310 (local only)
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            error.close()
            return None
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
            prompt_tokens, completion_tokens = _usage_counts(response_obj, kwargs)
            record = {
                "at": int(time.time()),
                "event": "success",
                "provider": meta.get(_PROVIDER_METADATA_KEY),
                "account": meta.get(_ACCOUNT_METADATA_KEY),
                "requested_model": meta.get("quotabot_original_model"),
                "served_model": kwargs.get("model"),
                "spend": meta.get(_SPEND_METADATA_KEY),
                "decision_id": meta.get(_DECISION_METADATA_KEY),
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "cost": _metric_cost(kwargs),
                "latency_ms": _latency_ms(start_time, end_time),
            }
            await asyncio.to_thread(self._append_metric, record)
        except Exception:
            return

    async def async_log_failure_event(
        self, kwargs: dict, response_obj: Any, start_time: Any, end_time: Any
    ) -> None:
        if not self.policy.metrics_path:
            return
        try:
            meta = (kwargs.get("litellm_params") or {}).get("metadata") or {}
            exception = kwargs.get("exception")
            prompt_tokens, completion_tokens = _usage_counts(response_obj, kwargs)
            record = {
                "at": int(time.time()),
                "event": "failure",
                "provider": meta.get(_PROVIDER_METADATA_KEY),
                "account": meta.get(_ACCOUNT_METADATA_KEY),
                "requested_model": meta.get("quotabot_original_model"),
                "served_model": kwargs.get("model"),
                "spend": meta.get(_SPEND_METADATA_KEY),
                "decision_id": meta.get(_DECISION_METADATA_KEY),
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "cost": _metric_cost(kwargs),
                "latency_ms": _latency_ms(start_time, end_time),
                "http_status": _extract_http_status(
                    kwargs,
                    response_obj,
                    exception,
                ),
                "retry_after_seconds": _extract_retry_after_seconds(
                    kwargs,
                    response_obj,
                    exception,
                ),
                "error_type": _error_type(exception),
            }
            await asyncio.to_thread(self._append_metric, record)
        except Exception:
            return

    def _append_metric(self, record: dict) -> None:
        if not self.policy.metrics_path:
            return
        path = Path(self.policy.metrics_path)
        _restrict_owner_only_directory(path.parent)
        fd: Optional[int] = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            with os.fdopen(fd, "a", encoding="utf-8") as fh:
                fd = None
                fh.write(json.dumps(record) + "\n")
        finally:
            if fd is not None:
                os.close(fd)
        _restrict_owner_only_file(path)


def _ranked_infos(value: Any) -> list[dict[str, Any]]:
    if value is None:
        return []
    if isinstance(value, list):
        return [entry for entry in value if isinstance(entry, dict)]
    if isinstance(value, dict):
        ranked = value.get("ranked")
        if isinstance(ranked, list):
            return [entry for entry in ranked if isinstance(entry, dict)]
        return [entry for entry in value.values() if isinstance(entry, dict)]
    return []


def _best_ranked_candidate(
    candidates: list[Candidate],
    ranked: list[dict[str, Any]],
    floor: float,
) -> Optional[tuple[Candidate, dict[str, Any]]]:
    for info in ranked:
        if not info.get("available"):
            continue
        if _effective_headroom(info) < floor:
            continue
        for candidate in candidates:
            if _candidate_matches_info(candidate, info):
                return candidate, info
    return None


def _candidate_matches_info(candidate: Candidate, info: dict[str, Any]) -> bool:
    if candidate.local:
        return False
    provider = _string_field(info, "provider")
    if not candidate.provider or candidate.provider != provider:
        return False
    account = _string_field(info, "account")
    return candidate.account is None or candidate.account == account


def _metric_info_for_candidate(
    info: dict[str, Any],
    ranked: list[dict[str, Any]],
    candidate: Candidate,
) -> dict[str, Any]:
    out = dict(info)
    if candidate.account:
        out["account"] = candidate.account
        return out
    accounts = set()
    provider = _string_field(info, "provider")
    for entry in ranked:
        if provider != _string_field(entry, "provider"):
            continue
        account = _string_field(entry, "account")
        if account:
            accounts.add(account)
    if len(accounts) != 1:
        out.pop("account", None)
    return out


def _effective_headroom(info: dict[str, Any]) -> float:
    value = info.get("effective_headroom_percent")
    if isinstance(value, (int, float)):
        return float(value)
    value = info.get("headroom_percent")
    return float(value) if isinstance(value, (int, float)) else 0.0


def _string_field(source: Optional[dict[str, Any]], key: str) -> Optional[str]:
    if not source:
        return None
    value = source.get(key)
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def _valid_decision_id(value: Optional[str]) -> bool:
    if value is None:
        return False
    parts = value.split("-")
    return (
        len(parts) == 3
        and parts[0] == "qb"
        and 1 <= len(parts[1]) <= 20
        and parts[1].isdigit()
        and len(parts[2]) == 16
        and all(char in "0123456789abcdef" for char in parts[2])
    )


def _availability_decision_id(value: Any) -> Optional[str]:
    decision_id = getattr(value, "decision_id", None)
    return decision_id if _valid_decision_id(decision_id) else None


def _usage_counts(*sources: Any) -> tuple[Optional[int], Optional[int]]:
    for source in sources:
        usage = _usage_source(source)
        if usage is None:
            continue
        prompt = _non_negative_int(
            _field(usage, "prompt_tokens"),
            _field(usage, "input_tokens"),
        )
        completion = _non_negative_int(
            _field(usage, "completion_tokens"),
            _field(usage, "output_tokens"),
        )
        if prompt is not None or completion is not None:
            return prompt, completion
    return None, None


def _usage_source(value: Any) -> Any:
    if value is None:
        return None
    usage = _field(value, "usage")
    if usage is not None:
        return usage
    if isinstance(value, dict):
        response = value.get("response_obj") or value.get("response")
        usage = _field(response, "usage") if response is not None else None
        if usage is not None:
            return usage
        for key in ("usage_object", "usage"):
            if value.get(key) is not None:
                return value[key]
    return None


def _metric_cost(kwargs: dict) -> Optional[float]:
    for key in ("response_cost", "cost"):
        parsed = _non_negative_float(kwargs.get(key))
        if parsed is not None:
            return parsed
    return None


def _non_negative_int(*values: Any) -> Optional[int]:
    for value in values:
        if isinstance(value, bool):
            continue
        if isinstance(value, int) and value >= 0:
            return value
        if isinstance(value, float) and value.is_integer() and value >= 0:
            return int(value)
    return None


def _non_negative_float(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        parsed = float(value)
        if math.isfinite(parsed) and parsed >= 0:
            return parsed
    return None


def _latency_ms(start_time: Any, end_time: Any) -> Optional[int]:
    start = _timestamp_seconds(start_time)
    end = _timestamp_seconds(end_time)
    if start is None or end is None:
        return None
    delta = end - start
    if delta < 0 or delta > 86400:
        return None
    return int(round(delta * 1000))


def _timestamp_seconds(value: Any) -> Optional[float]:
    if isinstance(value, (int, float)):
        parsed = float(value)
        return parsed if parsed >= 0 else None
    timestamp = getattr(value, "timestamp", None)
    if callable(timestamp):
        try:
            parsed = float(timestamp())
            return parsed if parsed >= 0 else None
        except Exception:
            return None
    return None


def _status_code(value: Any) -> Optional[int]:
    if isinstance(value, int):
        return value if 100 <= value <= 599 else None
    if isinstance(value, float) and value.is_integer():
        parsed = int(value)
        return parsed if 100 <= parsed <= 599 else None
    return None


def _field(value: Any, name: str) -> Any:
    if isinstance(value, dict):
        return value.get(name)
    return getattr(value, name, None)


def _extract_http_status(*sources: Any) -> Optional[int]:
    for source in sources:
        if source is None:
            continue
        for name in ("status_code", "status", "http_status", "code"):
            parsed = _status_code(_field(source, name))
            if parsed is not None:
                return parsed
        response = _field(source, "response")
        if response is not None:
            parsed = _extract_http_status(response)
            if parsed is not None:
                return parsed
    return None


def _headers(value: Any) -> dict[str, Any]:
    if value is None:
        return {}
    headers = _field(value, "headers")
    if isinstance(headers, dict):
        return headers
    if headers is None:
        return {}
    try:
        return dict(headers)
    except Exception:
        return {}


def _extract_retry_after_seconds(*sources: Any) -> Optional[int]:
    for source in sources:
        candidates = [_headers(source)]
        response = _field(source, "response") if source is not None else None
        if response is not None:
            candidates.append(_headers(response))
        for headers in candidates:
            for key, value in headers.items():
                if str(key).lower() != "retry-after":
                    continue
                parsed = _retry_after_seconds(value)
                if parsed is not None:
                    return parsed
    return None


def _retry_after_seconds(value: Any) -> Optional[int]:
    if isinstance(value, (int, float)):
        seconds = int(value)
        return seconds if seconds >= 0 else None
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    try:
        seconds = int(float(text))
        return seconds if seconds >= 0 else None
    except ValueError:
        pass
    try:
        dt = email.utils.parsedate_to_datetime(text)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        delta = dt - datetime.datetime.now(datetime.timezone.utc)
        seconds = int(round(delta.total_seconds()))
        return max(0, seconds)
    except Exception:
        return None


def _error_type(value: Any) -> Optional[str]:
    if value is None:
        return None
    name = type(value).__name__.strip()
    if not name or name == "NoneType":
        return None
    allowed = []
    for char in name[:80]:
        if char.isalnum() or char in {"_", "."}:
            allowed.append(char)
    parsed = "".join(allowed)
    return parsed or None


# The proxy references this instance by attribute path in config.yaml.
proxy_handler_instance = QuotabotRouter()
