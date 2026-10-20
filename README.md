# Redeploy

A small iPhone app that lists your Portainer stacks and pulls and redeploys a Git-based Compose
stack with one tap, after a Face ID confirmation. It talks straight to Portainer's REST API over
Tailscale; there is no backend and there are no third-party dependencies.

> **Status: first version, not yet built.** The code was written in an environment without
> Xcode or a Swift compiler, so the first build on a Mac may need small fixes. See
> [First build](#first-build).

## Requirements

- Xcode 16 or later (the project uses synchronized folders, `objectVersion = 77`)
- iOS 17 or later on the device
- Portainer reachable from the phone, ideally over Tailscale
- A Portainer API token

## Setup

### 1. Create an API token

In Portainer: **My account → Access tokens → Add access token**. Copy it; Portainer shows it only
once. The app stores it in the iOS Keychain (this device only, readable only while unlocked) and
never logs it or writes it to `UserDefaults`.

### 2. Give Portainer an address the phone can reach

Recommended: put Portainer behind `tailscale serve` on the Portainer host, which gives it a valid
HTTPS certificate for its `*.ts.net` name:

```sh
# Portainer's HTTPS port (self-signed certificate) behind a trusted Tailscale certificate
tailscale serve --bg https+insecure://localhost:9443
# or Portainer's HTTP port
tailscale serve --bg http://localhost:9000
```

Then use `https://<host>.<tailnet>.ts.net` as the server address in the app.

Other options:

- **Portainer's own HTTPS on :9443** uses a self-signed certificate. iOS rejects it, and the app
  does not disable certificate validation. You'd need to install and trust your own CA on the
  phone.
- **Plain HTTP** is blocked by App Transport Security. The app has no ATS exception today. If
  you need one, add an `Info.plist` with `NSAppTransportSecurity → NSAllowsLocalNetworking = YES`.
  That covers IP addresses such as `http://100.x.y.z:9000`, unqualified names and `.local`, but
  **not** a full `*.ts.net` name over HTTP.

The first connection triggers iOS's Local Network prompt; allow it.

### 3. Configure the app

On first launch the app opens **Settings**: enter the server address and token, tap **Save and
test connection**, and pick the environment. You should see "Reachable · Portainer x.y.z".

## First build

1. Open `Redeploy.xcodeproj`.
2. Select the **Redeploy** target → **Signing & Capabilities** → choose your team. The bundle ID
   is `nl.r-huijts.phonetainer`; automatic signing is on and `DEVELOPMENT_TEAM` is empty on
   purpose.
3. Run the tests: **Product → Test** (⌘U) on an iPhone simulator, or
   `xcodebuild test -scheme Redeploy -destination 'platform=iOS Simulator,name=iPhone 16'`.
4. Run on the simulator with demo data: **Product → Scheme → Edit Scheme → Run → Arguments** and
   tick `--demo`. This uses an in-memory fake Portainer, so you can click through every screen
   without a server.
5. Untick `--demo` and run on your phone.

If the build fails, the likely causes are small API or type mismatches. Fixes are welcome as
commits; the logic is covered by the unit tests.

## How it works

| Screen | What it does |
|---|---|
| Stacks | Lists the selected environment's stacks with live container status (Running n/m, Degraded, Stopped). Non-Git and non-Compose stacks are shown disabled. Pull to refresh. |
| Confirm | Summary of what will happen, toggles for re-pulling images and pruning, then Face ID (passcode as fallback). |
| Progress | Honest states: Starting → Redeploying (request in flight / Portainer says "deploying") → Verifying (polling containers) → Done or Failed, with elapsed time. "Run in background" keeps it going. |
| Activity | The last 50 redeploys from this app, stored locally. |
| Settings | Server, token, environment, connection test, and safety toggles. |

API details (endpoints, the redeploy body, and how Portainer 2.39 and newer versions differ) are in
[`docs/api-notes.md`](docs/api-notes.md). The manual test list is in
[`docs/test-checklist.md`](docs/test-checklist.md).

### Safety

- Every redeploy asks for confirmation, and for Face ID unless you turn that off.
- One redeploy at a time; no batch or silent redeploys.
- The redeploy request sends the stack's current branch, environment variables and stored Git
  credentials back unchanged, because Portainer 2.39 overwrites them otherwise.
- A rejected token (HTTP 401) sends you to Settings with an explanation.

## Project layout

```
Redeploy/
  App/        RedeployApp, AppState, AppSettings, RedeployRun (the redeploy state machine)
  Core/       Models, PortainerClient (+ live and mock), KeychainStore, DeviceAuthentication,
              Notifier, ActivityStore
  Features/   Stacks, Confirm, Progress, Activity, Settings
  Design/     Theme tokens, StatusChip, StackCard, button styles
RedeployTests/  Unit tests and JSON fixtures
scripts/portainer_spike.py   Checks the API against a real Portainer (Phase 0)
```

## Checking the API against your Portainer

```sh
export PORTAINER_URL=https://<host>.<tailnet>.ts.net
export PORTAINER_TOKEN=ptr_...
python3 scripts/portainer_spike.py inspect
python3 scripts/portainer_spike.py redeploy --stack-id <id> --confirm-name <throwaway-stack>
```

`inspect` is read-only. `redeploy` recreates the stack's containers, so use a throwaway stack.
Both write sanitized JSON to `spike-output/` (gitignored). After reviewing it, it can replace the
synthetic fixtures in `RedeployTests/Fixtures/`.
