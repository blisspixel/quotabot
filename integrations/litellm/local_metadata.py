"""Bounded loopback metadata transport, with optional same-peer authentication."""

from __future__ import annotations

import base64
import asyncio
import hashlib
import hmac
import http.client
import ipaddress
import json
import math
import secrets
import socket
import ssl
import threading
import time
import urllib.parse
from collections.abc import Callable
from contextvars import ContextVar
from typing import ParamSpec, TypeVar

LOCAL_METADATA_TIMEOUT_SECONDS = 2.0
_SERVER_PROOF_SCHEMA = "quotabot.local-server-proof.v1"
_MAX_SERVER_PROOF_BYTES = 4096
_P = ParamSpec("_P")
_T = TypeVar("_T")
_OPERATION_DEADLINE: ContextVar[float | None] = ContextVar(
    "quotabot_local_metadata_deadline", default=None
)


async def run_metadata_operation(
    operation: Callable[_P, _T], *args: _P.args, **kwargs: _P.kwargs
) -> _T | None:
    # A socket deadline cannot interrupt an OS name resolver before a socket
    # exists. Bound the async caller too; the worker checks its expired deadline
    # and closes any later connection before issuing metadata or sending a token.
    end = time.monotonic() + LOCAL_METADATA_TIMEOUT_SECONDS
    inherited = _OPERATION_DEADLINE.get()
    if inherited is not None:
        end = min(end, inherited)
    context_token = _OPERATION_DEADLINE.set(end)
    try:
        remaining = end - time.monotonic()
        if remaining <= 0:
            return None
        return await asyncio.wait_for(
            asyncio.to_thread(operation, *args, **kwargs),
            timeout=remaining,
        )
    except asyncio.TimeoutError:
        return None
    finally:
        _OPERATION_DEADLINE.reset(context_token)


def is_loopback_url(url: str) -> bool:
    if (
        not isinstance(url, str)
        or not url
        or url != url.strip()
        or "\\" in url
        or any(char.isspace() for char in url)
    ):
        return False
    try:
        parsed = urllib.parse.urlsplit(url)
        port = parsed.port
    except ValueError:
        return False
    host = parsed.hostname
    if (
        parsed.scheme.lower() not in {"http", "https"}
        or not parsed.netloc
        or not host
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
        or port == 0
    ):
        return False
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def local_server_proof(token: str, nonce: str, endpoint: str) -> str:
    message = f"quotabot-local-server-proof-v1\n{nonce}\n{endpoint}"
    return hmac.new(
        token.encode("utf-8"), message.encode("utf-8"), hashlib.sha256
    ).hexdigest()


def _local_server_endpoint(peer_socket: socket.socket) -> str:
    peer: object = peer_socket.getpeername()
    if not isinstance(peer, tuple) or len(peer) < 2:
        raise ValueError("missing loopback peer")
    host, port = peer[:2]
    if not isinstance(host, str) or not isinstance(port, int):
        raise ValueError("invalid loopback peer")
    address = ipaddress.ip_address(host.split("%", 1)[0])
    if not address.is_loopback or not 1 <= port <= 65535:
        raise ValueError("peer is not loopback")
    encoded = base64.urlsafe_b64encode(address.packed).rstrip(b"=").decode("ascii")
    return f"{encoded}:{port}"


class _Deadline:
    """Stop header and body reads even when a peer keeps sending tiny fragments."""

    def __init__(self, connection: http.client.HTTPConnection, end: float) -> None:
        self._connection = connection
        self._socket: socket.socket | None = None
        self._end = end
        self._timer = threading.Timer(max(0, end - time.monotonic()), self.abort)
        self._timer.daemon = True

    def start(self) -> None:
        self._timer.start()

    def attach(self, peer_socket: socket.socket) -> None:
        self._socket = peer_socket
        self.check()

    def check(self) -> float:
        remaining = self._end - time.monotonic()
        if remaining <= 0:
            self.abort()
            raise TimeoutError("local metadata deadline expired")
        if self._socket is not None:
            self._socket.settimeout(remaining)
        return remaining

    def abort(self) -> None:
        # HTTPResponse can retain the socket after HTTPConnection clears its
        # reference for a closing response. Keep the owned original reference.
        peer_socket = self._socket or self._connection.sock
        if peer_socket is not None:
            try:
                peer_socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                # A peer that already closed needs no further shutdown.
                pass

    def close(self) -> None:
        self._timer.cancel()
        self._connection.close()
        if self._socket is not None:
            self._socket.close()


class _OwnedHTTPSConnection(http.client.HTTPSConnection):
    """Expose the TLS socket before its handshake so the deadline can abort it."""

    def __init__(self, host: str, port: int | None, timeout: float) -> None:
        self._deadline: _Deadline | None = None
        context = ssl.create_default_context()
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.set_alpn_protocols(["http/1.1"])
        self._tls_context = context
        super().__init__(host, port, timeout=timeout, context=context)

    def set_deadline(self, deadline: _Deadline) -> None:
        self._deadline = deadline

    def connect(self) -> None:
        if self._deadline is None:
            raise ValueError("TLS metadata connection requires an owned deadline")
        http.client.HTTPConnection.connect(self)
        if self.sock is None:
            raise OSError("local metadata connection has no socket")
        self._deadline.attach(self.sock)
        tls_socket = self._tls_context.wrap_socket(
            self.sock, server_hostname=self.host, do_handshake_on_connect=False
        )
        self.sock = tls_socket
        self._deadline.attach(tls_socket)
        tls_socket.do_handshake()


def _read_bounded_response(
    response: http.client.HTTPResponse, maximum: int, deadline: _Deadline
) -> bytes | None:
    if response.length is not None and response.length > maximum:
        return None
    raw = bytearray()
    while len(raw) <= maximum:
        deadline.check()
        # read1 performs at most one underlying read. read(n) can repeatedly
        # wait for n bytes while a trickling peer resets the socket idle timeout.
        part = response.read1(min(65536, maximum + 1 - len(raw)))
        deadline.check()
        if not part:
            if response.length not in (None, 0):
                return None
            return bytes(raw)
        raw.extend(part)
    return None


def local_metadata_request(
    base_url: str,
    path: str,
    token: str | None,
    *,
    method: str = "GET",
    body: bytes | None = None,
    maximum: int,
    timeout: float = LOCAL_METADATA_TIMEOUT_SECONDS,
) -> bytes | None:
    """Read bounded metadata using one deadline and one owned TCP connection.

    HTTPConnection bypasses environment proxies and never follows redirects.
    An authenticated exchange proves possession of the token before sending it.
    """
    started = time.monotonic()
    if not is_loopback_url(base_url) or maximum < 0:
        return None
    if not math.isfinite(timeout) or timeout <= 0:
        return None
    end = started + timeout
    inherited = _OPERATION_DEADLINE.get()
    if inherited is not None:
        end = min(end, inherited)
    parsed = urllib.parse.urlsplit(base_url)
    host = parsed.hostname
    if host is None:
        return None
    connection_type = (
        _OwnedHTTPSConnection
        if parsed.scheme.lower() == "https"
        else http.client.HTTPConnection
    )
    connection: http.client.HTTPConnection | None = None
    deadline: _Deadline | None = None
    try:
        remaining = end - time.monotonic()
        if remaining <= 0:
            return None
        connection = connection_type(host, parsed.port, timeout=remaining)
        deadline = _Deadline(connection, end)
        if isinstance(connection, _OwnedHTTPSConnection):
            connection.set_deadline(deadline)
        deadline.start()
        connection.timeout = deadline.check()
        connection.connect()
        original_socket = connection.sock
        if original_socket is None:
            return None
        deadline.attach(original_socket)
        endpoint = _local_server_endpoint(original_socket)
        if token is not None:
            nonce = secrets.token_urlsafe(32)
            challenge_path = "/auth/prove?" + urllib.parse.urlencode({"nonce": nonce})
            connection.request(
                "GET", challenge_path, headers={"Accept": "application/json"}
            )
            with connection.getresponse() as challenge_response:
                challenge_raw = _read_bounded_response(
                    challenge_response, _MAX_SERVER_PROOF_BYTES, deadline
                )
                if (
                    challenge_response.status != 200
                    or challenge_response.will_close
                    or challenge_raw is None
                    or connection.sock is not original_socket
                ):
                    return None
            challenge: object = json.loads(challenge_raw.decode("utf-8"))
            if not isinstance(challenge, dict):
                return None
            proof: object = challenge.get("proof")
            if (
                challenge.get("schema") != _SERVER_PROOF_SCHEMA
                or challenge.get("nonce") != nonce
                or not isinstance(proof, str)
                or len(proof) != 64
                or any(char not in "0123456789abcdef" for char in proof)
                or not hmac.compare_digest(
                    proof, local_server_proof(token, nonce, endpoint)
                )
                or connection.sock is not original_socket
            ):
                return None
        deadline.check()
        headers = {"Accept": "application/json"}
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        if body is not None:
            headers["Content-Type"] = "application/json"
            headers["Content-Length"] = str(len(body))
        connection.request(method, path, body=body, headers=headers)
        with connection.getresponse() as response:
            if not 200 <= response.status < 300:
                return None
            return _read_bounded_response(response, maximum, deadline)
    except (
        http.client.HTTPException,
        OSError,
        UnicodeError,
        ValueError,
        RecursionError,
    ):
        return None
    finally:
        if deadline is not None:
            deadline.close()
        elif connection is not None:
            connection.close()
