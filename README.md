# Brick Hub

An NFC "brick" app blocker for iPhone. It works entirely on its own, and if
you use **Home Assistant**, any HA trigger can brick it too: a time, leaving
home, the TV turning on, a door sensor or an NFC reader by the door.

No AI, no accounts, no cloud service of ours.

```
                     ┌──────────────── iPhone (the boss) ────────────────┐
 tap your brick ───► │ rules · strict mode · emergency unbricks · 48h    │
 timer / schedule ─► │ reset · tags · stats  ──►  Screen Time shields    │
 iOS Shortcut ─────► │                                                   │
                     └───────▲────────────────────────────┬──────────────┘
                   commands  │ push / long-poll           │ reports its state
                  (optional) │ dropped if not delivered   ▼ (optional)
                     ┌───────┴──── Home Assistant ─────────────────────────┐
 any HA trigger ───► │ brick_hub.brick / unbrick ...   mirror entities     │
 ESPHome NFC ──────► │ tag scans forwarded to the phone   + events         │
                     └─────────────────────────────────────────────────────┘
```

**The phone makes every decision.** Home Assistant can *ask* it to brick or
unbrick, and it shows what the phone reports, but it can't override the rules.
If HA is down, unreachable or never installed, nothing changes on the phone.

## Features

| | Brick | Brick Hub |
|---|---|---|
| Tap an NFC tag to brick / unbrick | ✅ | ✅ any NTAG sticker, card or fob |
| Works without anything else | ✅ | ✅ |
| Modes | ✅ | ✅ block list **or** allow list, apps + categories + websites |
| Prevent deleting apps while bricked | ✅ | ✅ per mode |
| Schedules | ✅ | ✅ on-device, work with no signal |
| Timed bricks | ✅ | ✅ can be extended, never shortened |
| Emergency unbricks | ✅ 5, then email support | ✅ configurable, then a **reset that takes 2 days** |
| Stats | ✅ | ✅ today, 7 days, streak, longest; also as HA sensors |
| Triggers | the tag | the tag, timers, schedules, iOS Shortcuts automations, **any Home Assistant trigger**, ESPHome NFC readers |
| Strict mode | — | ✅ manual unbricks refused |
| Needs a hardware purchase | ✅ the Brick | ❌ any NFC tag |

## The rules (set in the app, locked while bricked)

**Strict mode** (on by default). Only these can end a brick:

* scanning a registered brick tag
* the timer running out
* the on-device schedule that started the brick ending
* a **Home Assistant automation** (automations can end any brick)
* an emergency unbrick

These count as *manual* and are refused in strict mode: the app's Unbrick
button, the "Unbrick Phone" Shortcut, and a person flipping the switch or
running a script by hand in the HA dashboard. While bricked you also can't
change the rules, edit modes or schedules, or add or remove tags.

**Emergency unbricks.** You get 5 by default. Each one ends a brick
immediately. Once you've used some, tap **Request reset**: they refill
**48 hours later** (adjustable). No email, no support ticket. Asking again
doesn't restart the countdown, and raising the number doesn't refill
anything. Optionally the reset starts by itself when you run out. While
bricked or while a reset is pending, the app uses Screen Time to require
automatic date and time, so winding the clock forward can't finish the reset
early. (This setting hasn't been tried on a real device yet.)

## What you need

* **An iPhone** on iOS 17+ and **a Mac with Xcode 16+** to install the app.
* **An Apple Developer Program membership (A$149/year).** Apple only lets
  apps use the Screen Time API with the Family Controls entitlement, which a
  free account can't get. Push notifications from HA need it too.
  Development builds you install from Xcode last a year without App Store review.
* **NFC tags** (optional): any NTAG213/215/216 sticker, card or key fob, e.g.
  from Core Electronics, Jaycar or Amazon AU. Nothing needs writing to them.
* **Home Assistant** 2025.1+ (optional).

## Install the app

```sh
brew install xcodegen
cd ios
# edit project.yml: set BRICK_BUNDLE_ID (e.g. com.yourname.brickhub) and DEVELOPMENT_TEAM
xcodegen
open BrickHub.xcodeproj
```

Run the **BrickHub** scheme on your iPhone. Xcode's automatic signing sets
up the App Group, Family Controls, NFC and Push capabilities for the app and
its three extensions. Then:

1. Allow Screen Time access.
2. **Modes →** create a mode, e.g. *Deep work*: block social and games, and
   prevent deleting apps.
3. **Settings → Add a brick tag →** scan your sticker. Put it somewhere inconvenient.
4. **Settings → Rules →** strict mode, number of emergency unbricks, reset delay.

That's it. Everything works from here without Home Assistant.

## Add Home Assistant (optional)

### 1. Install the integration

**HACS:** add this repository as a custom repository (type *Integration*),
install **Brick Hub** and restart. **Manual:** copy `custom_components/brick_hub`
into `config/custom_components/` and restart. Then go to *Settings → Devices & services →
Add integration → Brick Hub*.

### 2. Push key (recommended)

Push is how HA reaches the phone instantly, even with the app closed.
Without it, HA commands only arrive while the app is open.

1. On [developer.apple.com](https://developer.apple.com/account/resources/authkeys/list),
   go to *Keys* → **+**, enable **Apple Push Notifications service (APNs)**,
   download the `.p8` file and note the **Key ID**.
2. Note your **Team ID** (top right of the developer site).
3. In HA: *Brick Hub → Configure*. Paste the Team ID, Key ID, your bundle ID
   and the full contents of the `.p8` file.

Push style **Notification** (default) is the most reliable. The app's
notification extension runs the command the moment the push lands, then
rewrites the banner to say what happened. For example, *"Bricked · Bedtime ·
until 6:30 am · by Bedtime"*, or *"Didn't do that: Strict mode is on…"*.
**Silent** shows no banner, but iOS may delay or drop silent pushes.

### 3. Link the phone

In the app: **Settings → Link Home Assistant**. Enter your HA URL and a
long-lived access token (HA profile → *Security*). A URL that works away
from home (Nabu Casa, Tailscale, a reverse proxy) lets the phone report from
anywhere. Pushes go through Apple and reach the phone either way.

The phone then appears in HA as a device with its own entities. Link more
phones the same way.

### Commands that don't arrive are dropped

A command from HA is valid for **2 minutes**. If the phone doesn't get it in
time (flight mode, no signal, push disabled and app closed), it's dropped
rather than applied later. HA fires `brick_hub_command_result` with code
`no_response`, so you can be notified. If the phone receives it late, the
phone drops it itself.

### Entities (per phone)

| Entity | |
|---|---|
| `switch.<phone>_bricked` | the phone's real state. Flipping it *sends a command*; it only changes once the phone confirms |
| `select.<phone>_mode` | unbricked: the mode HA uses when an automation doesn't name one. Bricked: the active mode |
| `button.<phone>_emergency_unbrick`, `…_request_emergency_reset`, `…_cancel_emergency_reset` | |
| `sensor.<phone>_emergency_unbricks_remaining`, `…_emergency_reset_completes` | |
| `sensor.<phone>_bricked_since`, `…_brick_ends` | |
| `sensor.<phone>_time_bricked_today`, `…_time_bricked_7_days`, `…_streak` | stats from the phone |
| `sensor.<phone>_last_change_by` | manual / tag / automation / timer / schedule / emergency |
| `sensor.<phone>_last_report` | when the phone last checked in |
| `binary_sensor.<phone>_screen_time_access` | problem: Screen Time access was revoked |

The mirror stays right between reports. A timed brick shows as ended when
its time is up, and a reset shows as complete when it's due. The phone does
both itself, offline, at exactly those times.

### Services

```yaml
action: brick_hub.brick
data:
  device_id: abc123     # optional; default = every linked phone
  mode: Deep work       # mode name from the app; optional
  duration: "01:30:00"  # optional - the phone unbricks itself after this
  source: Office        # label shown on the phone
```

There are also `brick_hub.unbrick`, `brick_hub.toggle`, `brick_hub.emergency_unbrick`,
`brick_hub.request_emergency_reset`, `brick_hub.cancel_emergency_reset`,
`brick_hub.add_tag` and `brick_hub.remove_tag`.

### Events

* `brick_hub_command_result`: the phone's answer to each command (`ok`,
  `code`, `message`, `action`, `phone`). Codes include `strict_mode`,
  `unknown_mode`, `no_emergency_unbricks`, `expired` (arrived too late) and
  `no_response` (never confirmed).
* `brick_hub_state_changed`: whenever the phone reports a change (`bricked`,
  `mode`, `method`, `source`, `ends_at`, `emergency_remaining`).

### NFC readers around the house

The phone shares *hashes* of its brick tags with HA, never the tag IDs
themselves. When any reader HA knows about scans one of them (an ESPHome
PN532/RC522, or the HA Companion app), HA forwards it to that phone, which
treats it like a tap. IDs are normalised: `04:A1:B2`, `04-a1-b2` and `04A1B2`
match.

See [`examples/automations.yaml`](examples/automations.yaml).

## iOS Shortcuts

The app adds **Brick Phone** (mode, minutes), **Scan Brick**,
**Unbrick Phone** (manual, so refused in strict mode) and **Is Phone
Bricked**. Any iOS automation trigger (Focus, arriving somewhere, CarPlay,
an alarm, a charger) can brick the phone without HA.

## Limitations

* iOS always lets you revoke Screen Time access in Settings, after Face ID or
  your passcode. Brick has the same weakness. Brick Hub can't stop it, but HA
  shows it (`binary_sensor.<phone>_screen_time_access`), so you can automate a
  consequence.
* Schedules and timers run in an extension with no network access. HA learns
  about schedule-started bricks the next time the app runs or refreshes in
  the background. Timer ends are worked out by HA itself.
* Apple requires DeviceActivity intervals to be at least 15 minutes and allows
  about 20 monitored schedules per app. Short timers are handled by starting
  the interval early.
* Running HA commands from the notification extension follows Apple's model
  (ManagedSettings is usable from an app's extensions), but this hasn't been
  tried on a real device yet. If your iOS version doesn't allow it, the
  command runs when you tap the notification or open the app, as long as
  that's within 2 minutes.
* The app's screens haven't been compiled in Xcode yet, since this was built
  without a Mac. Expect a few small fixes on the first build.

## Development

```sh
# Home Assistant integration
pip install -r requirements_test.txt
pytest

# The phone's engine: rules, emergency unbricks, reset, HA commands (runs on Linux too)
cd ios/BrickCore && swift test
```
