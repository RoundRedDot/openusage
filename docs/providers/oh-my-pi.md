# Oh My Pi

Tracks local tokens and estimated spend from the [Oh My Pi](https://github.com/can1357/oh-my-pi)
coding agent. There is no OpenUsage login or API key to configure.

## What It Tracks

| Metric | Meaning |
|---|---|
| Usage Trend | Daily tokens over the last month |
| Today / Yesterday / Last 30 Days | Local estimated cost and tokens, with a per-model breakdown |

All four metrics start enabled. Usage Trend is always visible; the spend rows are On Demand.
None starts pinned to the menu bar. Provider enablement follows the usual local detection and
saved choices. There are no account quota meters on this card.

## Data Source

OpenUsage recursively reads JSONL logs under `~/.omp/agent/sessions/`, including subagent folders.
Both assistant `message` entries and OMP's separate `model_usage` entries count. Copied entries
with the same ID count once. No transcript text is sent to a service.

Path resolution follows OMP on macOS:

- `OMP_PROFILE` selects `~/.omp/profiles/<name>/agent/sessions`; `PI_PROFILE` is used only when
  `OMP_PROFILE` is absent. An empty value or `default` selects the default profile.
- In the default profile, `PI_CODING_AGENT_DIR` overrides the agent directory.
- `PI_CONFIG_DIR` changes the config-root name (normally `.omp`).
- After an OMP XDG migration, an existing `$XDG_DATA_HOME/omp` (or its named profile directory)
  supplies the `sessions` directory. A custom agent-directory override takes precedence.

`PI_CODING_AGENT_SESSION_DIR` belongs to Pi and is not used for OMP. A command's custom
`--session-dir` outside these roots is not discovered automatically.

## Cost and Counting

OMP has its own card and cache. Its usage is not added to the Pi, Claude, or Codex cards.
Live provider quota meters remain account-wide. Days follow your Mac's local time zone.

Like the Pi card, positive recorded costs are used directly; absent or zero costs are estimated
with OpenUsage's shared model pricing. Codex requests use its dated pricing and free auto-review
rules. These dollars are estimates, not invoices or subscription charges. Unknown prices are
reported in the spend-row warning and excluded from totals. Token totals use the recorded value;
when missing, they are calculated from the usage buckets, including orchestration tokens.

## Troubleshooting

- **Oh My Pi not detected**: run `omp` to create a session log, then refresh OpenUsage.
- **Invalid Oh My Pi profile**: correct `OMP_PROFILE` or `PI_PROFILE`; invalid names are reported
  rather than reading a different profile.
- **No data**: no priced usage was found in the last 30 days. Check any unknown-model warning.
