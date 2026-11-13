# Prison Life — Client API & Obfuscated Script Research

A reproducible research notebook for **Prison Life** (Roblox PlaceId
`155615604`): the game's client-side remote API, and two widely distributed
Luraph-obfuscated scripts — **Anomaly** (`anomaly.pw`) and **KX Admin**
(`kxadminv2.onrender.com`).

This repository documents what the Prison Life client actually exposes and ships
a reference script built only on those confirmed remotes. It contains no
server-side bypass, no licence key, and does not redistribute the third-party
obfuscated payloads it analyses. Using the script violates Roblox's terms of
service; it is published for study and interoperability work.

---

## What is here

| Path | Contents |
|---|---|
| [`PrisonLife.lua`](PrisonLife.lua) | The reference script: self-contained UI, ESP, camera assist, auto-arrest, giver/tool collection, team switching, teleports, anti-AFK and fullbright, built from the documented remotes. |
| [`docs/PrisonLife-Deobfuscated-API.md`](docs/PrisonLife-Deobfuscated-API.md) | The main result: 103 client scripts, 93 per-script constant sections, the confirmed remote list, teams, item/giver behaviour, gun attributes, and every string constant recovered from the client dump. |
| [`docs/Anomaly-and-KX.md`](docs/Anomaly-and-KX.md) | Loader chains, Luraph v15.1 identification, the nested KX stage-2 VM, and the deserialization result. |
| [`docs/Methodology.md`](docs/Methodology.md) | How the data was recovered, what is confirmed vs. inferred, and the limits of a client-only dump. |
| [`loaders/`](loaders/) | The five loader stubs as distributed (Anomaly route selector, key-gated Anomaly stub, KX free loader, KX GitHub loader, hosted `kxadm.lua`). |
| [`artifacts/`](artifacts/) | SHA-256 manifest and small extracted-constant files. Large payloads are intentionally not committed. |
| [`tools/run_vm.lua`](tools/run_vm.lua) | LuaJIT harness that deserializes a dumped Luraph/KX stage-2 VM. |
| [`tools/transpile_luau.py`](tools/transpile_luau.py) | Source transpiler used to turn Luau-flavoured VM dumps into LuaJIT-loadable code. |

---

## Script

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/reizure87-create/prison-life-research/main/PrisonLife.lua"))()
```

`PrisonLife.lua` is self-contained (no WindUI or other external dependency) and
works on PC and touch. It uses only remotes named in the API reference:

| Area | Implementation |
|---|---|
| ESP | `Highlight` + `BillboardGui`, team colours, distance, health bar, max-distance slider |
| Camera | smooth aim assist inside a configurable FOV; team check |
| Arrest | `ArrestPlayer:FireServer(target)` for nearby `Criminals` / `Hostile` / `Trespassing` |
| Givers | `GiverPressed` and `TouchGiver` on objects with a `ToolName` attribute or a known tool name |
| Items | `InteractWithItem:InvokeServer(tool)` with a per-tool cooldown |
| Teams | `RequestTeamChange:InvokeServer(teamName)` |
| Movement | `RequestHere:FireServer(position)` for cursor, player-list and behind-target teleports |
| Settings | `GetSettings:InvokeServer()` |
| Misc | anti-AFK, fullbright, rejoin, config persistence through executor `writefile` when available |

Every remote call is `pcall`-guarded. If a remote is missing, the UI reports it
instead of firing. Argument shapes are inferred from the dump, so the server may
reject a call — the script does not claim server-side success.

Verification status: the script parses under LuaJIT and was exercised with a
mocked Roblox environment (window construction, every toggle/tab/slider/button,
ESP object creation, aim frame, all six remote paths, and clean unload). It has
**not** been run against a live Roblox client in this environment, so treat
gameplay behaviour as untested.

---

## Headline findings

### Prison Life client API

- **103 client-reachable scripts** were recovered: 54 `LocalScript`, 19
  `Script` (client/shared `RunContext`), 30 `ModuleScript`. Nothing under
  `ServerScriptService` or `ServerStorage` is present — Roblox never replicates
  server code to the client.
- **17 remotes** are documented, including `RequestTeamChange`, `RequestHere`,
  `GiverPressed`, `InteractWithItem`, `TouchGiver`, `ArrestPlayer`,
  `ShootEvent`, `meleeEvent`, `UpdateSetting`, `GetSettings`,
  `RequestCollisionChange`, `ReplicateEvent`, `InnocentWarnEvent`,
  `BuyGamepassRequested`, `VoiceTeleportRequested`, `mouseLockToggledEvent`,
  and `SwitchTeams`.
- Teams are `Guards`, `Inmates`, `Criminals` (Hostile), plus `Neutral`.
- Gun behaviour is driven by attributes (`MaxAmmo`, `FireRate`, `Range`,
  `Damage`, `ReloadTime`, `Behavior`, `AutoFire`, …) and shots go through
  `ShootEvent`.
- The full remote table and per-script constant dumps are in
  [`docs/PrisonLife-Deobfuscated-API.md`](docs/PrisonLife-Deobfuscated-API.md).

### Anomaly (`anomaly.pw`)

- `anomaly_loader.lua` routes by `game.GameId`:
  - `73885730` → `https://anomaly.pw/prisonlife`
  - `7414497778` → `https://anomaly.pw/mtc4`
  - `4750561026` → `https://anomaly.pw/coldwar`
  - `1526814825` → `https://anomaly.pw/wartycoon`
- Unsupported games copy `https://discord.gg/auBaHr6juB` to the clipboard and
  kick the player.
- The generic key-gated stub fetches `https://anomaly.pw/script` and expects a
  global `key`.
- The Prison Life payload (`anomaly_pl.lua`, 552,365 bytes) is protected with
  **Luraph Obfuscator v15.1** (header comment and VM constants). Its static
  strings contain the Luraph VM's standard-library table only; the script's
  real configuration is decrypted at runtime.

### KX Admin (`kxadminv2.onrender.com`)

- `kxadm.lua` fetches `https://kxadminv2.onrender.com/kx-free/loader`.
- `kx_loader.lua` sets `KX_FREE_URL` and fetches the hashed asset
  `https://kxadminv2.onrender.com/kx-free/assets/094819024ddbe189eaa9d179ae3f5975.lua`.
- The 3,029,622-byte main payload is also Luraph v15.1. It contains a nested
  **stage-2 VM** (224,062 bytes) plus a **2,354,258-byte encrypted blob**.
- The stage-2 blob **deserializes successfully** under LuaJIT once the Luau
  runtime pieces are supplied: `table.pack`, `table.create`, `table.clear`,
  `coroutine.close`, `typeof`, `vector`, `buffer`, and `bit32`.
- The deserializer returns a callable function (`[deserialize] ok=true
  type=function`). Executing that function is a long-running VM interpretation;
  the harness logs decrypted strings as they appear. Static extraction is not
  enough to recover the runtime configuration.

---

## Reproduce

### 1. Read the API reference

No tooling required:

```sh
less docs/PrisonLife-Deobfuscated-API.md
```

### 2. Inspect the loaders

```sh
cat loaders/anomaly_loader.lua
cat loaders/kx_loader.lua
cat loaders/kxadm.lua
```

### 3. Deserialize a dumped stage-2 VM

Requirements: LuaJIT 2.1+ with `ffi` and `bit` (the Termux/PRoot build used
here is `LuaJIT 2.1.1794386141`). The VM and blob are not committed; obtain
them from the original research archive and verify the hashes in
[`artifacts/README.md`](artifacts/README.md).

```sh
luajit tools/run_vm.lua <kx_stage2_vm_clean.luajit.lua> <kx_stage2_data_clean.bin>
```

Expected output begins with:

```text
[load] vm=224062 data=2354258
[deserialize] ok=true type=function ...
```

The optional third argument `probe` stops after constructing the VM table and
reports missing numeric dependency slots; this is how the `table.pack` slot was
identified.

### 4. Transpile a Luau-flavoured dump

```sh
python3 tools/transpile_luau.py input.lua output.luajit.lua
```

---

## Confirmed vs. inferred

The API reference marks the remote table as **confirmed** (the names and call
sites are read from the dump) while argument shapes and purposes are
**inferred** from the calling script's context. The analysis documents use the
same rule:

- **Confirmed** — a byte sequence, URL, hash, loader path, header comment, or
  runtime result reproduced by the harness.
- **Inferred** — authorship, intent, which remote argument means what, or what
  a decrypted branch does without executing it.

No result here was invented to fill a gap. Where execution was impractical,
the limitation is stated.

---

## Limits

- A client dump cannot contain server scripts. The server's validation logic
  (shot validation, arrest checks, purchase checks, team balance) is simply not
  on the client. The only server-authoritative surface is the remote list.
- Luau bytecode → source is not fully reversible by hand. The API reference is
  built from string constants and call-site context, not from reconstructed
  source.
- The KX stage-2 payload is a nested interpreter running a 2.35 MB encrypted
  program. Deserialization is fast; full execution is CPU-bound and was not
  required to recover the client API.
- The Anomaly and KX payloads are third-party works. Their licences and terms
  are unknown; this repository documents them for interoperability and security
  research and does not redistribute the large payloads.

---

## Ethics and legal

This repository is intended for:

- understanding the game's client/server contract,
- auditing scripts that claim to implement Prison Life features,
- building defensive detections for the loader domains and VM fingerprints.

It is **not** intended to bypass server authority, steal accounts, or
redistribute paid scripts. Do not run unknown Roblox scripts on an account you
care about. The loader domains and hashes are listed for defenders; treat them
as indicators, not as endorsement.

Original code and prose in this repository are MIT-licensed (see `LICENSE`).
Third-party scripts, game assets, and obfuscated payloads remain the property
of their respective authors.
