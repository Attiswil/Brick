# Brick Hub

An NFC "brick" app blocker for iPhone, powered by **Home Assistant**. Any
Home Assistant trigger can brick your phone: a time, leaving home, the TV
turning on, a door sensor, a tag scan or a button. The iPhone app blocks the
apps with Apple's own Screen Time API.

No AI, no accounts, no cloud service of ours. State lives in your Home
Assistant and on your phone.

```
 any HA trigger ──► brick_hub.brick ──► Brick Hub integration (source of truth)
 (time, zone, TV,                          │  rules: strict mode, emergency
  door, ESPHome NFC…)                      │  unbricks, 48 h reset, timers
                                           ▼
                         APNs push  ──►  iPhone (notification extension applies
                         long-poll  ──►   the Screen Time shield immediately)
                                           ▲
 tap your NFC brick in the app ────────────┘  (works offline too, syncs later)
```

## Features

| | Brick | Brick Hub |
|---|---|---|
| Tap an NFC tag to brick / unbrick | ✅ | ✅ any NTAG sticker, card or fob |
| Modes (block list) | ✅ | ✅ block list **or** allow list, apps + categories + websites |
| Prevent deleting apps while bricked | ✅ | ✅ per mode |
| Schedules | ✅ | ✅ on-device (works with no signal) **plus** anything HA can do |
| Timed bricks | ✅ | ✅ and timers can only be extended, never shortened |
| Emergency unbricks | ✅ 5, then email support | ✅ configurable, then a **reset that takes 2 days** |
| Stats | ✅ | ✅ today, 7 days, streak, longest; also as HA sensors |
| Triggers | the tag | the tag, **any Home Assistant trigger**, iOS Shortcuts automations, ESPHome NFC readers, the HA Companion app's tag scanner |
| Strict mode | — | ✅ manual unbricks refused; only a tag, timer, schedule, automation or emergency unbrick ends a brick |
| Works offline | ✅ | ✅ offline actions are queued and replayed to HA |
| Knows if you turned off Screen Time access | — | ✅ `binary_sensor.brick_hub_screen_time_access`, so you can automate a nag |
| Needs a hardware purchase | ✅ the Brick | ❌ any NFC tag (or none) |

### Emergency unbricks and the 2-day reset

You get a limited number of emergency unbricks (5 by default). Each one ends a
brick immediately, whatever the rules. When you've used some, press
**Request reset** in the app or in Home Assistant. Your allowance refills
**48 hours later** (you can change the delay). There's no email and no support
ticket. When connected, the countdown runs on Home Assistant's clock, so
changing the phone's clock doesn't speed it up. Requesting again doesn't restart it, and raising the
maximum doesn't refill anything. You can optionally have the reset start
automatically when you run out.

### Strict mode (on by default)

These can always end a brick:

* scanning a registered brick tag (in the app, or with any NFC reader HA knows about)
* a timer running out
* the on-device schedule that started the brick ending
* a Home Assistant **automation** calling `brick_hub.unbrick`
* an emergency unbrick

**Manual** unbricks are refused. That covers flipping the switch in the HA
dashboard, running a script by hand, and the app's "Unbrick" button. Home
Assistant tells these apart by whether a logged-in person made the call.
While you're bricked you also can't change settings, edit modes or schedules,
or add or remove tags.

## What you need

* **Home Assistant** 2025.1 or newer.
* **An iPhone** on iOS 17+ and **a Mac with Xcode 16+**.
* **An Apple Developer Program membership (A$149/year).** Apple only lets
  apps use the Screen Time API with the Family Controls entitlement, and push
  notifications need it too. A free account can't do either. Development
  builds you install from Xcode work for a year without Apple's review. You
  only need to request the Family Controls *distribution* entitlement if you
  want TestFlight or the App Store.
* **NFC tags** (optional). Any NTAG213/215/216 sticker, card or key fob works,
  e.g. from Core Electronics, Jaycar or Amazon AU. The app reads the tag's
  built-in ID, so nothing needs writing to it.
* **Remote access to HA** (recommended) so the phone can sync away from home,
  e.g. Home Assistant Cloud (Nabu Casa), Tailscale or your own reverse proxy.
  Pushes from HA to the phone go through Apple and work regardless.

## Install

### 1. Home Assistant integration

**HACS:** add this repository as a custom repository (type *Integration*),
install **Brick Hub**, then restart Home Assistant.
**Manual:** copy `custom_components/brick_hub` into your HA `config/custom_components/`
and restart.

Then go to *Settings → Devices & services → Add integration → Brick Hub*
and choose your rules: emergency unbricks, reset delay (48 h), strict mode.

### 2. Push key (recommended)

Push lets HA wake the phone the instant a trigger fires, even if the app has
been swiped away.

1. Go to [developer.apple.com](https://developer.apple.com/account/resources/authkeys/list) → *Keys* → **+**, and enable
   **Apple Push Notifications service (APNs)**. Download the `.p8` file and note the **Key ID**.
2. Note your **Team ID** (top right of the developer site).
3. In HA: *Brick Hub → Configure*. Paste the Team ID, Key ID, your app's
   bundle ID and the full contents of the `.p8` file.

Push styles:
* **Notification** (default, most reliable): a short banner such as
  *"Bricked · Deep work · until 5:00 pm · by Office"*. A notification service
  extension applies the brick before the banner appears, even if the app is closed.
* **Silent**: no banner, but iOS may delay or drop silent pushes, especially in Low Power Mode.
* **Off**: the phone only updates when the app is open, via long-polling or
  background refresh.

### 3. iPhone app

```sh
brew install xcodegen
cd ios
# edit project.yml: set BRICK_BUNDLE_ID (e.g. com.yourname.brickhub) and DEVELOPMENT_TEAM
xcodegen
open BrickHub.xcodeproj
```

Select the **BrickHub** scheme, plug in your iPhone, and run. Xcode's automatic
signing registers the App Group, Family Controls, NFC and Push capabilities
for the app and its three extensions. Use the same bundle ID in HA's push
settings.

On first launch, allow Screen Time access, then:

1. **Modes →** create a mode (e.g. *Deep work*: block social and games, and
   prevent deleting apps). Mode names show up in HA's `select.brick_hub_mode`.
2. **Settings → Add a brick tag →** scan your sticker. Put it somewhere inconvenient.
3. **Settings → Connect Home Assistant →** your HA URL plus a long-lived access
   token (HA profile → *Security* → *Long-lived access tokens*).
4. **Settings → Enable notifications** (needed for pushes).

The app also works **standalone** without HA, using tags, timers and
schedules. In that case the rules live on the phone.

## Using it from Home Assistant

### Entities

| Entity | |
|---|---|
| `switch.brick_hub_bricked` | on = bricked. Attributes: mode, source, method |
| `select.brick_hub_mode` | the default mode (or the active one while bricked) |
| `button.brick_hub_emergency_unbrick` | spend one |
| `button.brick_hub_request_emergency_reset` / `…cancel…` | the 2-day reset |
| `sensor.brick_hub_emergency_unbricks_remaining` | |
| `sensor.brick_hub_emergency_reset_completes` | timestamp |
| `sensor.brick_hub_bricked_since`, `sensor.brick_hub_brick_ends` | timestamps |
| `sensor.brick_hub_time_bricked_today`, `…_7_days`, `sensor.brick_hub_streak` | stats |
| `sensor.brick_hub_last_change_by` | manual / tag / automation / timer / schedule / emergency |
| `binary_sensor.brick_hub_phone_in_sync` | every phone has applied the latest state |
| `binary_sensor.brick_hub_screen_time_access` | problem: a phone revoked Screen Time access |

### Services

```yaml
action: brick_hub.brick
data:
  mode: Deep work      # name or id; optional
  duration: "01:30:00" # optional - auto-unbrick
  source: Office       # optional label shown on the phone
```

There are also `brick_hub.unbrick`, `brick_hub.toggle`, `brick_hub.emergency_unbrick`,
`brick_hub.request_emergency_reset`, `brick_hub.cancel_emergency_reset`,
`brick_hub.add_tag` and `brick_hub.remove_tag`.

### Events

* `brick_hub_state_changed` fires on every change, with `bricked`, `mode`,
  `method`, `source`, `ends_at` and `emergency_remaining`. Use it as a trigger
  for lights, sounds or logging.
* `brick_hub_command_refused` fires when something was refused (`code`, `message`).

### Tags from anywhere

Brick Hub listens to Home Assistant's `tag_scanned` event. A tag registered
in the app also works with an **ESPHome NFC reader** (PN532/RC522) or the
**HA Companion app's** tag scanner, because IDs are normalised: `04:A1:B2`,
`04-a1-b2` and `04A1B2` all match. Scanning a known tag unbricks. If you're
unbricked it bricks, unless you turn that off.

See [`examples/automations.yaml`](examples/automations.yaml) for bedtime,
leaving home, TV-on, office-light, a nag automation and more.

### iOS Shortcuts

The app adds **Brick Phone** (with mode and minutes), **Scan Brick**,
**Unbrick Phone** (refused in strict mode) and **Is Phone Bricked**. So any iOS
automation trigger (Focus mode, arriving somewhere, connecting to CarPlay,
an alarm, plugging in a charger) can brick the phone too, with or without HA.

## How it stays reliable

* **Shields persist.** Once applied, iOS enforces them even if the app is
  closed or the phone restarts.
* **Push → notification service extension.** It applies the new state from
  the push payload itself, with no network round trip, then acknowledges to HA.
* **Long-poll** while the app is open, so changes show up within about a second.
* **Background refresh** catches anything missed.
* **Offline first.** If HA is unreachable, the phone applies the action with
  an identical local engine (`ios/Shared/BrickEngine.swift` mirrors
  `engine.py`) and queues it. Queued actions replay in order, each with a
  unique ID so nothing applies twice. HA state never overwrites unsent local
  changes. Emergency unbricks used offline are still counted.
* **Timers and schedules** are also registered with iOS DeviceActivity, so the
  phone unbricks at the right time even with no signal.
* **The phone can't lie its way out.** HA only accepts "timer" if the timer
  really ended, "schedule" only for a schedule-started brick, and "tag" only
  for a registered tag. Anything else counts as manual.

## Honest limitations

* iOS always lets you revoke Screen Time access in Settings, which needs Face
  ID or your passcode. Brick has the same weakness. Brick Hub can't stop it,
  but it reports it to HA so you can automate a consequence.
* Apple requires DeviceActivity intervals to be at least 15 minutes and allows
  about 20 monitored schedules per app. Short timers are handled by
  starting the interval early.
* The fastest path applies the brick from the notification service extension.
  Apple documents ManagedSettings as usable from an app's extensions, but this
  path hasn't been tested on a real device yet. If your iOS version doesn't
  allow it, the state is applied the next time the app opens or refreshes in
  the background. Tapping the notification also opens the app and applies it.
* You build and sign the app yourself. That's what makes it free of accounts
  and trackers, but it needs the paid developer membership.

## Development

```sh
pip install -r requirements_test.txt
pytest
```

The tests cover the state machine (`tests/test_engine.py`) and the full
integration (`tests/test_integration.py`): services, strict mode, timers, the
48-hour reset, tag scans, the phone API, long-polling, push fan-out and
persistence.
