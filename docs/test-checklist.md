# Manual test checklist

Run on a physical iPhone with a throwaway Git-based Compose stack. Tick each item.

## Setup and connection

- [ ] Fresh install opens on Settings, and the Stacks tab says "Not connected".
- [ ] A wrong address (e.g. `nope.invalid`) shows "Can't reach the server…" after Save and test.
- [ ] A self-signed `https://…:9443` address shows the certificate message, not a spinner.
- [ ] A wrong token shows "Portainer rejected the API token…" and the red banner in Settings.
- [ ] The correct address and token show "Reachable · Portainer x.y.z · n environments".
- [ ] The environment picker lists the same environments as Portainer's UI.
- [ ] The token field never shows the saved token; after a restart it says "Saved".
- [ ] The Local Network prompt appears once, on first connection.

## Stacks list

- [ ] The list matches Portainer's stacks for the selected environment.
- [ ] Status chips match reality: Running n/m, Degraded n/m (stop one container to check), Stopped.
- [ ] Branch, short commit and "Redeployed … ago" are correct.
- [ ] Non-Git stacks show a disabled "Not Git-based" button.
- [ ] Pull to refresh and the refresh button both reload.
- [ ] The connection line says "Connected via Tailscale · host" for a `ts.net` or `100.x` address.
- [ ] With Tailscale turned off, the list shows a clear error and "Try again".

## Redeploy

- [ ] "Pull & redeploy" opens the confirm sheet with the right stack name and branch.
- [ ] "Re-pull images" starts on the default from Settings.
- [ ] Cancel closes the sheet; nothing is sent.
- [ ] Cancelling Face ID leaves the sheet open with no error.
- [ ] Face ID succeeds → progress shows Starting → Redeploying (elapsed time counts up) → Verifying → Done.
- [ ] The stack's environment variables are still there in Portainer afterwards.
- [ ] The branch is unchanged in Portainer afterwards.
- [ ] A private repository redeploys (stored credentials kept).
- [ ] Commit and "Redeployed … ago" update in the list after finishing.
- [ ] A success haptic plays.
- [ ] The Activity tab shows the entry with result and duration.

## Failures

- [ ] Push a broken compose file → the redeploy fails with Portainer's message, not a spinner.
- [ ] Revoke the token in Portainer, then redeploy → clear 401 message; Settings shows the banner.
- [ ] Turn Tailscale off mid-redeploy → message says it may still be running on the server.
- [ ] A failure haptic plays; Activity records the failure.

## Background and notifications

- [ ] The first redeploy asks for notification permission (not at launch).
- [ ] "Run in background", then go to the home screen → a notification arrives when it finishes.
- [ ] Back in the app, the stack card is up to date.
- [ ] While a redeploy runs, other stacks' redeploy buttons are disabled; tapping the running
      card's button reopens progress.

## Accessibility and appearance

- [ ] With the largest Dynamic Type size, all screens remain usable (nothing clipped or overlapping).
- [ ] VoiceOver reads each card as name, status, branch/commit and time; the refresh button reads "Refresh".
- [ ] Status is readable without color (every chip has text).
- [ ] The app stays in the light theme with Dark Mode on.
