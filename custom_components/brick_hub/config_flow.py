"""Config and options flow for Brick Hub."""

from __future__ import annotations

import time
from typing import Any

import jwt
import voluptuous as vol

from homeassistant.config_entries import (
    ConfigEntry,
    ConfigFlow,
    ConfigFlowResult,
    OptionsFlow,
)
from homeassistant.core import callback
from homeassistant.helpers.selector import (
    SelectSelector,
    SelectSelectorConfig,
    TextSelector,
    TextSelectorConfig,
)

from .const import (
    CONF_APNS_BUNDLE_ID,
    CONF_APNS_KEY,
    CONF_APNS_KEY_ID,
    CONF_APNS_TEAM_ID,
    CONF_PUSH_STYLE,
    DEFAULT_BUNDLE_ID,
    DOMAIN,
    NAME,
    PUSH_ALERT,
    PUSH_STYLES,
)


class BrickHubConfigFlow(ConfigFlow, domain=DOMAIN):
    """Initial setup."""

    VERSION = 1

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        await self.async_set_unique_id(DOMAIN)
        self._abort_if_unique_id_configured()
        if user_input is not None:
            return self.async_create_entry(title=NAME, data={})
        return self.async_show_form(step_id="user", data_schema=vol.Schema({}))

    @staticmethod
    @callback
    def async_get_options_flow(config_entry: ConfigEntry) -> OptionsFlow:
        return BrickHubOptionsFlow()


def _validate_apns_key(team_id: str, key_id: str, key: str) -> None:
    jwt.encode(
        {"iss": team_id, "iat": int(time.time())},
        key.strip(),
        algorithm="ES256",
        headers={"kid": key_id},
    )


class BrickHubOptionsFlow(OptionsFlow):
    """Push settings. (The brick rules live in the iPhone app.)"""

    async def async_step_init(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        return await self.async_step_push()

    async def async_step_push(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        cur = {**self.config_entry.data, **self.config_entry.options}
        errors: dict[str, str] = {}
        if user_input is not None:
            team = (user_input.get(CONF_APNS_TEAM_ID) or "").strip()
            key_id = (user_input.get(CONF_APNS_KEY_ID) or "").strip()
            key = (user_input.get(CONF_APNS_KEY) or "").strip()
            if any((team, key_id, key)):
                if not all((team, key_id, key)):
                    errors["base"] = "apns_incomplete"
                else:
                    try:
                        await self.hass.async_add_executor_job(
                            _validate_apns_key, team, key_id, key
                        )
                    except Exception:  # noqa: BLE001 - any failure = bad key
                        errors[CONF_APNS_KEY] = "apns_bad_key"
            if not errors:
                return self.async_create_entry(data=user_input)

        schema = vol.Schema(
            {
                vol.Required(
                    CONF_PUSH_STYLE, default=cur.get(CONF_PUSH_STYLE, PUSH_ALERT)
                ): SelectSelector(
                    SelectSelectorConfig(
                        options=PUSH_STYLES, translation_key=CONF_PUSH_STYLE
                    )
                ),
                vol.Optional(
                    CONF_APNS_TEAM_ID, default=cur.get(CONF_APNS_TEAM_ID, "")
                ): TextSelector(),
                vol.Optional(
                    CONF_APNS_KEY_ID, default=cur.get(CONF_APNS_KEY_ID, "")
                ): TextSelector(),
                vol.Optional(
                    CONF_APNS_BUNDLE_ID,
                    default=cur.get(CONF_APNS_BUNDLE_ID, DEFAULT_BUNDLE_ID),
                ): TextSelector(),
                vol.Optional(
                    CONF_APNS_KEY, default=cur.get(CONF_APNS_KEY, "")
                ): TextSelector(TextSelectorConfig(multiline=True)),
            }
        )
        return self.async_show_form(step_id="push", data_schema=schema, errors=errors)
