# Portainer API notes (Phase 0)

Status: **source-checked, not yet verified against the real instance.**

The findings below come from reading Portainer's Go source at tag `2.39.8` (the latest release
line) and at `develop` (API version 2.45.0, October 2026). The redeploy endpoint changed a lot
between those two, so which version my instance runs matters. The "Real instance" column gets
filled in after running `scripts/portainer_spike.py` against it.

## Endpoints

| Purpose | Plan said | Source says | Real instance |
|---|---|---|---|
| Version | (not listed) | `GET /api/system/version` (`ServerVersion`); older: `GET /api/status` | ☐ |
| Environments | `GET /api/endpoints` | same | ☐ |
| Stacks | `GET /api/stacks` | same | ☐ |
| Single stack | `GET /api/stacks/{id}` | same | ☐ |
| Redeploy Git stack | `PUT /api/stacks/{id}/git/redeploy?endpointId={eid}` | **`PUT`** confirmed (both versions). `POST /api/stacks/{id}/git` is a different call: it changes the stored Git settings and does not redeploy. | ☐ |
| Containers | `GET /api/endpoints/{eid}/docker/containers/json?all=true&filters=…` | Docker API proxy; filter JSON is `{"label":["com.docker.compose.project=<name>"]}` | ☐ |

Auth header `X-API-Key: <token>` is accepted on every route above (`@security ApiKeyAuth`).

## Redeploy request

Field names are PascalCase (Go struct without JSON tags). JSON decoding in Go is
case-insensitive, so the camelCase names in the plan also work, but the app will send PascalCase.

| Field | 2.39.8 | develop (2.45) | What the app sends |
|---|---|---|---|
| `endpointId` (query) | Optional in theory, but if it differs from the stack's `EndpointId` the stack is re-pointed to it; leaving it out sets it to 0 and the call fails | same | **Always** the stack's `EndpointId` |
| `RepositoryReferenceName` | **Always overwrites** the branch, even with `""` | Empty keeps the stored branch | The stack's current `GitConfig.ReferenceName` |
| `Env` | **Always overwrites**; omitting it wipes the stack's variables | `null`/omitted keeps them | The stack's current `Env` array, unchanged |
| `Prune` | `bool`, only applied to Swarm stacks | `*bool`, applied to Compose and Swarm; omitted keeps stored | The toggle value |
| `RepullImageAndRedeploy` | yes | yes | The "Re-pull images" toggle |
| `PullImage` | deprecated alias (since 2.36), OR'ed with the above | same | Same value, for older servers |
| `RepositoryAuthentication` | If `false`, the clone runs **without credentials** (private repos fail). If `true` with an empty password, the stored password is used | Stored credentials are always used; `true` + non-empty password replaces them | `true` when `GitConfig.Authentication` exists, plus its `Username` and an empty `RepositoryPassword` |
| `RepositoryAuthorizationType` | exists | removed | Copied from the stack when present |
| `StackName` | Kubernetes only | Kubernetes only | Not sent |

So the plan's note "the existing `Env` array must be sent back" is **correct for 2.39** and
harmless for newer versions. The same is true for the branch name.

## Redeploy response and timing

- **2.39.8: synchronous.** The handler clones, deploys (`docker compose up`, with image pulls) and
  only then answers `200` with the updated stack (`Status = 1`, new `GitConfig.ConfigHash`,
  new `UpdateDate`). This can take minutes, so the app needs a long request timeout.
- **develop: asynchronous for Compose/Swarm.** It answers `200` right away with `Status = 3`
  (deploying) and deploys in a goroutine. Success flips `Status` to `1`; failure sets `Status = 4`
  and appends `{Status, Time, Message}` to `DeploymentStatus`, and the commit hash is reverted.
- Either way the app should poll `GET /api/stacks/{id}` until `Status != 3`, then check containers.
  That maps cleanly onto the plan's honest states: *Redeploying* (request in flight, or
  `Status == 3`) → *Verifying* (containers) → *Done*/*Failed*.
- Errors: `400` (not a Git stack: `"Stack is not created from git"`), `403`, `404`, `409`
  (develop: a deployment is already in progress), `500` (clone failed, compose failed). The body
  is `{"message": "...", "details": "..."}`; show `message`, and `details` under it.

## Stack object

| Field | Notes |
|---|---|
| `Id`, `Name`, `EndpointId`, `Type` | `Type`: 1 Swarm, 2 Compose, 3 Kubernetes. v1 handles 2 only |
| `Status` | 1 active, 2 inactive (stopped), 3 deploying, 4 error (3 and 4 are new in recent versions) |
| `Env` | `[{"name": "...", "value": "..."}]` (lowercase keys) |
| `GitConfig` | `null` for non-Git stacks. Has `URL`, `ReferenceName`, `ConfigFilePath`, `ConfigHash`, `TLSSkipVerify`, `Authentication` (password blanked in responses) |
| `UpdateDate`, `UpdatedBy` | Unix seconds, username |
| `Option` | `{"Prune": bool}` or `null` |
| `CurrentDeploymentInfo` | develop only: `ConfigHash` of what is actually deployed |
| `DeploymentStatus` | develop only: status history of the current deployment |

To be confirmed on the real instance: whether `GET /api/stacks` (the list) already fills
`GitConfig` on develop, where Git config moved to a separate "workflow"/"source" store.

## "Update available" (stretch, not in v1)

There is no endpoint that returns the latest remote commit for a stack without redeploying.
Portainer's own UI does not show this either. Options for later: the GitOps auto-update settings
(`AutoUpdate`), or querying the Git host directly. Leaving it out of v1 as planned.

## Networking

- `tailscale serve --bg https+insecure://localhost:9443` (or `http://localhost:9000`) on the
  Portainer host gives a valid certificate for `https://<host>.<tailnet>.ts.net`, which iOS
  accepts without any ATS exception. This is the recommended setup.
- The spike script uses the system trust store, so it also tells you if iOS will reject the
  certificate.

## How to verify

```sh
export PORTAINER_URL=https://<host>.<tailnet>.ts.net
export PORTAINER_TOKEN=ptr_...          # My account → Access tokens
python3 scripts/portainer_spike.py inspect
python3 scripts/portainer_spike.py redeploy --stack-id <id> --confirm-name <throwaway-stack>
```

`inspect` is read-only. `redeploy` recreates the stack's containers and refuses to run unless
`--confirm-name` matches the stack's name. Both write sanitized JSON to `spike-output/`
(gitignored): env values, credentials, URLs, the Portainer hostname and IPv4 addresses are
redacted, and endpoint snapshots are dropped. Read through it before using it as test fixtures.

## Test fixtures

`RedeployTests/Fixtures/*.json` are **synthetic**, built from Portainer's Go structs (2.39 shape,
plus `stack-deploying.json` and `stack-error.json` in the newer asynchronous shape). Replace them
with reviewed files from `spike-output/` after running the spike against the real instance, and
note any decoding differences here.

## How the app uses this

- `LivePortainerClient` sends `X-API-Key` on every request over an ephemeral `URLSession`, with a
  20 s timeout, or 15 minutes for the redeploy call.
- `RedeployRun` fetches the stack fresh, sends the body above, polls `GET /api/stacks/{id}` every
  3 s while `Status == 3`, fails on `Status == 4` with the last `DeploymentStatus` message, then
  polls containers for up to 90 s.
- Prune: on 2.39 the flag only affects Swarm stacks; on Compose it is ignored there.
