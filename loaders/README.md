# Loaders

Small loader stubs collected during the research. They are included verbatim so
the routes and chains can be audited. They are **not** the full payloads; each
one fetches a remote script and executes it.

| File | What it does |
|---|---|
| `anomaly_loader.lua` | Selects an `anomaly.pw` URL from `game.GameId`; Prison Life is `73885730` → `https://anomaly.pw/prisonlife`. Unsupported games copy a Discord invite and kick. |
| `Prison-Life-anomalypw-235599.lua` | Key-gated stub: sets global `key` and fetches `https://anomaly.pw/script`; the file's comment points buyers at `https://discord.gg/hKYHQJB5SB` (`#buyer-info`). |
| `kxadm.lua` | Fetches `https://kxadminv2.onrender.com/kx-free/loader`. |
| `kx_loader.lua` | Sets `KX_FREE_URL` and fetches the hashed asset `.../kx-free/assets/094819024ddbe189eaa9d179ae3f5975.lua`. |
| `Prison-Life-KX-Admin-234648.lua` | Older GitHub-backed loader; fetches `https://raw.githubusercontent.com/Keraunius/213sadd23/refs/heads/main/kxadm.lua`. |

Do not execute these against a real account. They download and run remote code
with the full permissions of the executor. The URLs are listed for analysis and
defensive blocking, not as an invitation to run them.

The payload domains and paths are summarised in
[`../docs/Anomaly-and-KX.md`](../docs/Anomaly-and-KX.md).
