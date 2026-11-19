# Command-Line Interface

OpenUsage ships a one-shot `openusage` command for agents and scripts. It prints the documented
[`/v1/limits`](local-http-api.md#get-v1limits) JSON and exits; it never launches or leaves the menu-bar
app running. The output contains stable scalar limits and balances, not UI rows, colors, subtitles,
charts, or spend-history tiles.

```sh
openusage                 # every enabled provider, refreshing stale cache entries
openusage codex           # one provider, refreshing when its cache is stale
openusage codex --force   # refresh through the shared provider engine, cache, print, exit
```

The command and app import the same providers, authentication stores, pricing, refresh coordinator, and
snapshot cache. A normal read reuses snapshots less than five minutes old and refreshes missing or stale
ones. It does not talk to the menu-bar app, so it can print a newer account set than the one still on
screen.

`--force` first asks the running app, at `http://127.0.0.1:6736`, to re-read Claude accounts and refresh.
When that app answers 200, the command prints the app's limits and does not fetch again. A named provider
refreshes even if its card is turned off; a name that matches nothing is an error. The command refreshes
in its own process only when nothing is listening (the connection is refused). If a request reaches an
app and times out, the response cannot be read, or the app returns any other error status, the command
fails and does not refresh again. Codex accounts are not re-read by this request. Credentials are used
locally and never appear in the output.

A provider argument names providers by plain string matching, exactly like the
[local HTTP API](local-http-api.md): an exact provider ID names that provider, and a family ID
(`claude`, `codex`) names every account card of that family — with one account that's exactly the one
card, so existing usage keeps working unchanged as multi-account support arrives. The output envelope
contains every matched provider; an ID that names nothing exits with an error. There is no aliasing
or account-picking logic.

## Install on `PATH`

In OpenUsage, open **Settings → Command Line** and click **Install…**. After the standard macOS
administrator prompt, `openusage` is available globally in new terminal sessions. The installed symlink
points to the signed helper inside OpenUsage, so in-place app updates also update the command.

Exit codes are `0` for success, `2` for invalid arguments or an unknown provider, and `4` when a
refresh or local read fails.
