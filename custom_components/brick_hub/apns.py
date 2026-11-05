"""Minimal Apple Push Notification service client (token-based auth).

You bring your own APNs auth key (.p8) from your Apple Developer account,
so pushes go straight from Home Assistant to Apple - there is no middle-man
server and nothing leaves your setup except the push itself.
"""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass
from typing import Any

import httpx
import jwt

from homeassistant.core import HomeAssistant

_LOGGER = logging.getLogger(__name__)

HOST_PROD = "https://api.push.apple.com"
HOST_SANDBOX = "https://api.sandbox.push.apple.com"
TOKEN_TTL = 50 * 60  # Apple wants a refresh between 20 and 60 minutes


@dataclass
class PushResult:
    """Outcome of a single push."""

    status: int
    reason: str | None = None

    @property
    def ok(self) -> bool:
        return self.status == 200

    @property
    def token_dead(self) -> bool:
        return self.status == 410 or self.reason in {
            "BadDeviceToken",
            "Unregistered",
            "DeviceTokenNotForTopic",
        }


class ApnsClient:
    """Sends pushes over HTTP/2."""

    def __init__(
        self,
        hass: HomeAssistant,
        team_id: str,
        key_id: str,
        private_key: str,
        bundle_id: str,
    ) -> None:
        self._hass = hass
        self._team_id = team_id.strip()
        self._key_id = key_id.strip()
        self._key = private_key.strip()
        self.bundle_id = bundle_id.strip()
        self._jwt: str | None = None
        self._jwt_at = 0.0
        self._client: httpx.AsyncClient | None = None

    def _token(self) -> str:
        now = time.time()
        if self._jwt is None or now - self._jwt_at > TOKEN_TTL:
            self._jwt = jwt.encode(
                {"iss": self._team_id, "iat": int(now)},
                self._key,
                algorithm="ES256",
                headers={"kid": self._key_id},
            )
            self._jwt_at = now
        return self._jwt

    async def _get_client(self) -> httpx.AsyncClient:
        if self._client is None:
            # Building an SSL context does blocking I/O; keep it off the loop.
            self._client = await self._hass.async_add_executor_job(
                lambda: httpx.AsyncClient(http2=True, timeout=15)
            )
        return self._client

    async def validate(self) -> None:
        """Raise if the key can't sign a token."""
        await self._hass.async_add_executor_job(self._token)

    async def send(
        self,
        device_token: str,
        payload: dict[str, Any],
        *,
        sandbox: bool,
        background: bool,
        collapse_id: str | None = None,
    ) -> PushResult:
        client = await self._get_client()
        token = await self._hass.async_add_executor_job(self._token)
        headers = {
            "authorization": f"bearer {token}",
            "apns-topic": self.bundle_id,
            "apns-push-type": "background" if background else "alert",
            # Background pushes must use priority 5.
            "apns-priority": "5" if background else "10",
            "apns-expiration": str(int(time.time()) + 3600),
        }
        if collapse_id:
            headers["apns-collapse-id"] = collapse_id
        host = HOST_SANDBOX if sandbox else HOST_PROD
        try:
            resp = await client.post(
                f"{host}/3/device/{device_token}",
                content=json.dumps(payload, separators=(",", ":")),
                headers=headers,
            )
        except httpx.HTTPError as err:
            _LOGGER.warning("APNs request failed: %s", err)
            return PushResult(0, str(err))
        reason = None
        if resp.status_code != 200:
            try:
                reason = resp.json().get("reason")
            except ValueError:
                reason = resp.text[:200]
            _LOGGER.warning("APNs rejected push (%s): %s", resp.status_code, reason)
        return PushResult(resp.status_code, reason)

    async def close(self) -> None:
        if self._client is not None:
            await self._client.aclose()
            self._client = None
