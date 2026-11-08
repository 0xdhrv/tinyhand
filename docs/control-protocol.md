# Local control protocol

TinyHand's bundled executable accepts `--ctl` followed by one JSON request. This
allows Raycast, Alfred, scripts, and other local clients to use the existing overlay
and settings without simulating hotkeys or writing preferences from another process.

The application must already be running. A `--ctl` invocation sends a request to
that instance and exits; it does not create a second overlay or launch the app.

```sh
APP="/Applications/TinyHand.app"
"$APP/Contents/MacOS/TinyHand" --ctl '{"version":1,"operation":"status"}'
"$APP/Contents/MacOS/TinyHand" --ctl '{"version":1,"operation":"on"}'
"$APP/Contents/MacOS/TinyHand" --ctl '{"version":1,"operation":"style","style":"lavender","activate":true}'
"$APP/Contents/MacOS/TinyHand" --ctl '{"version":1,"operation":"clear"}'
"$APP/Contents/MacOS/TinyHand" --ctl '{"version":1,"operation":"off"}'
```

## Compatibility and startup

Discover the application by bundle identifier `com.kamranahmed.tinyhand`, rather
than assuming the installation path in the examples. Check for integer
`TinyHandControlVersion = 1` in its Info.plist **before** invoking the executable:
older builds may treat unrecognized arguments as a normal app launch.

When a request returns `not-running`, clients may launch the detected app with
macOS LaunchServices, then retry **status** until it acknowledges readiness.
Use a bounded deadline. An `unavailable` response can mean a starting, busy, or
incompatible running instance; do not spawn additional copies. Keep one copy of
TinyHand running at a time.

TinyHand still needs its own Accessibility permission to activate input handling.
The IPC client does not need Accessibility permission simply to send commands.
No permission prompts are displayed by the CLI; activation returns an error with
setup guidance when permission is missing.

## Requests

Every request requires `version: 1` and an `operation`. Extra fields and unknown
operations are rejected. All app operations execute on the main thread.

| Operation | Additional fields | Behavior |
| --- | --- | --- |
| `status` | None | Read native state and supported capabilities |
| `styles` | None | Discover built-in hands, laser, and custom hands |
| `on` / `off` | None | Idempotently activate/deactivate |
| `toggle` | None | Toggle the current native state once |
| `clear` | None | Clear ink without changing the pointer or active state |
| `style` | `style` (string), optional `activate` (boolean, default false) | Validate and select a pointer; optionally activate |
| `laser` | None | Activate and select the laser, preserving ink/audio preferences |
| `configure` | `settings` (nonempty object) | Validate all fields, then apply in one settings batch |
| `toggle-sound` | None | Toggle hand sound, leaving laser sound unchanged |
| `pin` | `style` (string), `pinned` (boolean) | Pin/unpin a native toolbar pointer |
| `settings` | None | Open native settings, exiting the overlay as the menu action does |
| `custom-hands` | None | Open the existing custom-hand creator, exiting the overlay |

Discover style IDs with `styles`; do not infer them from display names. Selection
rejects removed styles or unusable images. Pinning enforces the native maximum of
eight entries and retains at least one pin.

### Settings batches

```sh
"$APP/Contents/MacOS/TinyHand" --ctl '{"version":1,"operation":"configure","settings":{"style":"laser","ink":"red","fade":6,"handSound":false}}'
```

Allowed settings:

- `style`: an available pointer ID.
- `ink`: `match`, `red`, `orange`, `yellow`, `green`, `blue`, `purple`, `white`, `black`.
- `fade`: `0` (until cleared), `3`, `6`, or `10` seconds.
- `size`: a finite number within the native `sizeRange` returned by status.
- `shadow`, `handSound`, `laserSound`: booleans.
- `tapSound`: `thock`, `click`, `pop`, `wood`, `boop`, or `squeak`.

Omitted settings remain unchanged. Every field, including pointer availability,
is validated before any preferences are written. The batch sends one preferences
notification to refresh the running overlay. This supports client-owned presets
without exposing intermediate settings to the event loop. It is not a
crash-durable database transaction. Applying a batch preserves active state.

## Responses

Standard output contains one JSON object and a newline. A success includes the
state captured after the operation:

```json
{
  "version": 1,
  "ok": true,
  "state": {
    "running": true,
    "active": false,
    "style": "lavender",
    "accessibility": true,
    "appVersion": "1.0.2",
    "capabilities": ["status", "styles", "on", "off", "toggle", "clear", "style", "laser", "configure", "toggle-sound", "pin", "settings", "custom-hands"],
    "settings": {
      "ink": "match", "fade": 3, "size": 0.13, "shadow": true,
      "handSound": true, "laserSound": false, "tapSound": "thock"
    },
    "sizeRange": [0.08, 0.2],
    "pinned": ["lavender", "glove", "coral", "plush", "robot", "laser"]
  }
}
```

`styles` additionally returns an array of `{ id, name, type, thumbnail? }` objects.
`type` is `hand`, `custom`, or `laser`. `thumbnail` is an optional local path to
TinyHand's own cropped 128px image. Paths are temporary; clients should rediscover
them and provide a fallback icon. Custom images are never uploaded.

Errors have `ok: false` and `error: { code, message }`. Native handler errors also
include current `state`. Codes include `invalid-request`, `unknown-style`,
`missing-asset`, `toolbar-full`, `accessibility`, `activation-failed`,
`not-running`, and `unavailable`. Clients should handle unknown codes gracefully.

Exit codes: **0** acknowledged, **1** native rejection, **2** transport/usage error.
An unavailable connection means the state is unknown, not inactive.

Do not automatically replay mutations after a timeout or lost connection: the
request may have succeeded before its response was lost. Refresh status first;
prefer explicit `on`/`off` where possible. Replaying `toggle` could reverse the
first action. Clients should also validate the protocol version and returned
state before claiming success.

## Transport and trust boundary

The transport uses a Unix domain socket in a private directory under macOS's
per-user temporary directory, scoped by the app's bundle identifier. The directory
must belong to the current user with mode 0700; symlink directories are rejected.
The socket uses mode 0600, and both peers check user identity with `getpeereid`.
An exclusive file lock prevents a second server from replacing a live endpoint.

Requests are bounded to 16 KiB, responses to 2 MiB on the client, and connection
reads/writes use short deadlines. There is no network port, background state
polling, arbitrary shell execution, unrestricted preference writing, or need for
administrator privileges. Any process running as the same user may use this
interface: this is a same-user boundary, not per-application authorization.

## Tests

```sh
bash scripts/test-control.sh
swift build -c release --arch arm64 --arch x86_64
```

The control harness executes the production handler against in-memory native
dependencies, including permission-denial and input-tap-failure cases, and tests
the actual private Unix socket transport. It does not mutate user preferences or
activate the installed app. The full build checks integration with the real
native types. Build CI runs both steps.

Live validation should additionally cover granted/denied Accessibility, app
startup/shutdown, pointer and ink rendering, custom image addition/removal, rapid
invocations, multiple displays, full-screen apps, and supported macOS versions.
