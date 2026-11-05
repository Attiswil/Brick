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
    BooleanSelector,
    NumberSelector,
    NumberSelectorConfig,
    NumberSelectorMode,
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
    CONF_AUTO_RESET,
    CONF_EMERGENCY_MAX,
    CONF_PUSH_STYLE,
    CONF_RESET_HOURS,
    CONF_STRICT,
    CONF_TAG_TOGGLES,
    DEFAULT_AUTO_RESET,
    DEFAULT_BUNDLE_ID,
    DEFAULT_EMERGENCY_MAX,
    DEFAULT_RESET_HOURS,
    DEFAULT_STRICT,
    DEFAULT_TAG_TOGGLES,
    DOMAIN,
    NAME,
    PUSH_ALERT,
    PUSH_STYLES,
)


def _policy_schema(cur: dict[str, Any]) -> dict:
    return {
        vol.Required(
            CONF_EMERGENCY_MAX,
            default=cur.get(CONF_EMERGENCY_MAX, DEFAULT_EMERGENCY_MAX),
        ): NumberSelector(
            NumberSelectorConfig(min=0, max=20, step=1, mode=NumberSelectorMode.BOX)
        ),
        vol.Required(
            CONF_RESET_HOURS, default=cur.get(CONF_RESET_HOURS, DEFAULT_RESET_HOURS)
        ): NumberSelector(
            NumberSelectorConfig(
                min=1,
                max=336,
                step=1,
                unit_of_measurement="h",
                mode=NumberSelectorMode.BOX,
            )
        ),
        vol.Required(
            CONF_STRICT, default=cur.get(CONF_STRICT, DEFAULT_STRICT)
        ): BooleanSelector(),
        vol.Required(
            CONF_AUTO_RESET, default=cur.get(CONF_AUTO_RESET, DEFAULT_AUTO_RESET)
        ): BooleanSelector(),
        vol.Required(
            CONF_TAG_TOGGLES, default=cur.get(CONF_TAG_TOGGLES, DEFAULT_TAG_TOGGLES)
        ): BooleanSelector(),
    }


def _clean_numbers(data: dict[str, Any]) -> dict[str, Any]:
    out = dict(data)
    if CONF_EMERGENCY_MAX in out:
        out[CONF_EMERGENCY_MAX] = int(out[CONF_EMERGENCY_MAX])
    if CONF_RESET_HOURS in out:
        out[CONF_RESET_HOURS] = float(out[CONF_RESET_HOURS])
    return out


class BrickHubConfigFlow(ConfigFlow, domain=DOMAIN):
    """Initial setup."""

    VERSION = 1

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        await self.async_set_unique_id(DOMAIN)
        self._abort_if_unique_id_configured()
        if user_input is not None:
            return self.async_create_entry(title=NAME, data=_clean_numbers(user_input))
        return self.async_show_form(
            step_id="user", data_schema=vol.Schema(_policy_schema({}))
        )

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
    """Change policy and push settings - but never while bricked."""

    async def async_step_init(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        hub = getattr(self.config_entry, "runtime_data", None)
        if hub is not None and hub.engine.bricked:
            return self.async_abort(reason="locked_while_bricked")
        return await self.async_step_policy()

    async def async_step_policy(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        cur = {**self.config_entry.data, **self.config_entry.options}
        if user_input is not None:
            self._policy = _clean_numbers(user_input)
            return await self.async_step_push()
        return self.async_show_form(
            step_id="policy", data_schema=vol.Schema(_policy_schema(cur))
        )

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
                hub = getattr(self.config_entry, "runtime_data", None)
                if hub is not None and hub.engine.bricked:
                    return self.async_abort(reason="locked_while_bricked")
                return self.async_create_entry(data={**self._policy, **user_input})

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
