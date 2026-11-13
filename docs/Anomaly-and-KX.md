# Anomaly and KX Admin — Loader Chains and Stage-2 VM

This document covers the two obfuscated Prison Life payloads in the research
archive: **Anomaly** (`anomaly.pw`) and **KX Admin**
(`kxadminv2.onrender.com`). It records the loader paths, the protection
pipeline, and the point at which the KX stage-2 blob was successfully
deserialized.

> Scope note: this is static and sandboxed analysis. The payloads are
> third-party works and are not redistributed in this repository. Loader URLs
> and hashes are listed so defenders can block or identify them.

---

## 1. Artifact manifest

Large files are deliberately not committed. Verify them against
[`../artifacts/README.md`](../artifacts/README.md).

| Artifact | Size (bytes) | SHA-256 (first 16) | Role |
|---|---:|---|---|
| `anomaly_pl.lua` | 552,365 | `3f4e33416dc7999d` | Anomaly Prison Life payload (Luraph v15.1) |
| `anomaly_pl_clean.lua` | 583,207 | `a7ffda61de49b4f2` | Transpiled/cleaned Anomaly payload |
| `kx_main.lua` | 3,029,622 | `2787c672c244da18` | KX main payload (Luraph v15.1) |
| `kx_stage2_vm_clean.luajit.lua` | 224,062 | `0aeed49883eb503b` | Extracted stage-2 VM |
| `kx_stage2_data_clean.bin` | 2,354,258 | `a04e7555201ad773` | Encrypted stage-2 blob |

The Anomaly and KX payloads both begin with:

```lua
-- This file was protected using Luraph Obfuscator v15.1 [https://lura.ph/]
```

That header is a direct, confirmed identification of the protection tool.

---

## 2. Anomaly loader chain

`anomaly_loader.lua` is a 525-byte route selector. It does not contain the
payload; it chooses a URL from `game.GameId`:

```lua
local routes = {
    [7414497778] = "https://anomaly.pw/mtc4",
    [4750561026] = "https://anomaly.pw/coldwar",
    [73885730]   = "https://anomaly.pw/prisonlife",
    [1526814825] = "https://anomaly.pw/wartycoon",
}
local url = routes[game.GameId]
if not url then
    setclipboard("https://discord.gg/auBaHr6juB")
    local player = game:GetService("Players").LocalPlayer
    if player then
        player:Kick("Game is unsupported, discord set to clipboard")
    end
    return
end
return loadstring(game:HttpGet(url))(...)
```

Confirmed behaviour:

- Prison Life's GameId `73885730` maps to
  `https://anomaly.pw/prisonlife`.
- Unsupported games copy the Discord invite
  `https://discord.gg/auBaHr6juB` to the clipboard and kick the player.
- The payload is fetched and executed with `loadstring(...)(...)`.

The separately distributed stub
`Prison-Life-anomalypw-235599.lua` is key-gated:

```lua
-- Get key @ https://discord.gg/hKYHQJB5SB in #buyer-info channel
key=""
loadstring(game:HttpGet("https://anomaly.pw/script"))()
```

It sets a global `key` (empty in the distributed file), points buyers at the
Discord invite `https://discord.gg/hKYHQJB5SB` (`#buyer-info`), and fetches the
generic `https://anomaly.pw/script` route. The route itself is not readable
without the key/service; no key is included in this research.

> Code blocks in this document are reformatted for readability. URLs, keys,
> identifiers, and control flow are transcribed from the files in
> [`../loaders/`](../loaders/).

### Anomaly payload

`anomaly_pl.lua` is 552,365 bytes of Luraph v15.1 output. It ends with:

```lua
return setmetatable({ ... }, {}):BZ()(...)
```

`BZ` is the VM entry; `Fg()` initialises the VM state; the resulting function
is invoked with the loader's varargs. The static string table (see
`artifacts/anomaly_strings_full.txt`) contains only the Luraph VM's standard
library names and the ASCII-art banner:

```
task cancel spawn defer delay wait
Instance Vector3 Vector2 CFrame Random
identifyexecutor islclosure iscclosure loadstring debug
...
bit32 buffer table coroutine string
```

No plaintext loader URL, licence key, or Prison Life-specific string survives
in the static table. The configuration is decrypted by the VM at runtime.

---

## 3. KX Admin loader chain

Two small loaders are in circulation.

`kxadm.lua` (77 bytes) fetches the hosted loader:

```lua
loadstring(game:HttpGet("https://kxadminv2.onrender.com/kx-free/loader"))()
```

An older stub, `Prison-Life-KX-Admin-234648.lua`, fetches the same file from
GitHub instead:

```lua
loadstring(game:HttpGet(
  "https://raw.githubusercontent.com/Keraunius/213sadd23/refs/heads/main/kxadm.lua"
))()
```

`kx_loader.lua` (208 bytes) sets the base URL and fetches a content-addressed
asset:

```lua
local kx_env = (getgenv and getgenv()) or _G
kx_env.KX_FREE_URL = "https://kxadminv2.onrender.com"
loadstring(game:HttpGet(
  "https://kxadminv2.onrender.com/kx-free/assets/094819024ddbe189eaa9d179ae3f5975.lua"
))()
```

The hashed asset resolves to the 3,029,622-byte main payload. The main payload
is Luraph v15.1 and contains a **nested stage-2 VM** plus a 2,354,258-byte
encrypted blob. The extraction produced:

- `kx_stage2_vm_clean.luajit.lua` — 224,062 bytes;
- `kx_stage2_data_clean.bin` — 2,354,258 bytes.

The stage-2 VM is the part that was successfully deserialized.

---

## 4. Stage-2 VM architecture

The dumped VM is a single expression:

```lua
return setmetatable({ <methods and dependency slots> }, {}):xS(...)
```

- `<methods>` contains the VM's opcode handlers (`aS`, `zS`, `oS`, `NS`,
  `XS`, `CS`, `JS`, `BS`, …).
- Numeric slots in the same table bind Luau/Roblox globals, for example
  `[11]=buffer.writeu32`, `[30]=unpack`, `[45]=table.create`,
  `[48]=bit32.band`, `[54]=buffer.fromstring`, `[63]=string.unpack`,
  `[98]=table.clear`, `[105]=buffer.create`, `[107]=coroutine.create`,
  `[123]=buffer.readu8`, `[124]=buffer.readu32`.
- `xS(l, ...)` calls `l:TS()` to get the initial state, converts the varargs
  with `l[2](...)`, and enters the interpreter loop.
- `TS` and `wP` are state initialisers, not missing code:
  `TS` returns `true, 2, nil, …`; `wP` returns `true, 19, nil, …`.

The VM is a Luau-bytecode interpreter. Its input blob is a serialized prototype
table; the interpreter reconstructs the prototype and returns a callable
function. `l:JS(A, S, 2)(nil, l.d)` is the "build a closure from a prototype"
path that initially failed in the debug dump.

### The `unpack` false lead

The first clean-run attempt failed with:

```text
too many results to unpack
```

Instrumentation showed `unpack` being called with a table of exactly
2,354,258 entries — the size of the blob. The obvious reading was "the VM is
unpacking every byte of the blob", which is impossible under LuaJIT's 8,000
result limit.

The actual cause was a missing Luau global. The VM's dependency slot `[2]` is
`table.pack`, not `buffer.fromstring`:

```lua
-- yS: unpack the packed varargs
yS = function(l, G) return l[30](G, 1, G.n) end
...
-- xS: pack the input, then hand it to the interpreter
local V = l[2](...)
```

With `[2] = table.pack`, `V` is `{ n = 1, [1] = <buffer> }`; `yS(V)` unpacks
exactly one value (the buffer). The "2.35 MB unpack" was the earlier harness's
incorrect `[2] = buffer.fromstring`, which made `V` itself the buffer and
`G.n` its byte length.

This is a useful general lesson for running dumped Luau VMs under LuaJIT:
**check the expected slot semantics before adding a shim**. A plausible-looking
`buffer.fromstring` shim produced a spectacular but misleading failure.

### Required Luau polyfills

Stock LuaJIT 2.1 lacks several globals the VM expects. The harness supplies:

| Global | Why it is needed |
|---|---|
| `table.pack` | packs the VM's varargs (`[2]` slot) |
| `table.create` | preallocates arrays (`[45]` slot) |
| `table.clear` | clears tables (`[98]` slot) |
| `table.move` | array moves (Lua 5.1 lacks it) |
| `coroutine.close` | Luau coroutine cleanup (`[99]` slot) |
| `coroutine.isyieldable` | Luau coroutine query (`[86]` slot) |
| `typeof` | Roblox type query (`[71]` slot) |
| `vector.create` | Luau vector constructor (`[100]` slot) |
| `buffer.*` | Luau `buffer` library (create, read/write, bit access) |
| `bit32.*` | Luau 32-bit operations (band/bor/bxor/shifts/rotates/counts) |
| `string.pack` / `string.unpack` | bound at slots `[18]` / `[63]`; LuaJIT 2.1 has neither |
| `setfenv` wrapper | the VM probes C functions; `setfenv` must tolerate them |
| `debug.info` mock | the VM uses it to classify functions |

`tools/run_vm.lua` implements these and logs each external call. A `probe`
mode stops after building the VM table and reports missing numeric slots.

### Result

With `table.pack` and the polyfills in place:

```text
[load] vm=224062 data=2354258
[deserialize] ok=true type=function val=function: 0x...
```

The deserializer returns a callable function. That is a confirmed runtime
result, not an inference.

Executing the returned function is a different problem. The VM then decrypts
its own standard-library string table and begins interpreting the 2.35 MB
program. On the aarch64/PRoot CPU used here this is a long-running job; the
capture harness records strings as they are produced:

```text
[STR] "task"
[STR] "cancel"
...
[STR] "The debug library is required on Luau platforms. Please open a support ticket."
```

Those first strings are the Luraph VM's own dependency list, not the payload's
configuration. Full execution was not required to recover the client API in
[`PrisonLife-Deobfuscated-API.md`](PrisonLife-Deobfuscated-API.md).

---

## 5. What the static strings do and do not show

The extracted strings (`artifacts/kx_strings_full.txt`,
`artifacts/anomaly_strings_full.txt`) contain:

- the ASCII-art banner,
- the Luraph VM standard-library names (`task`, `Instance`, `Vector3`,
  `buffer`, `bit32`, `debug`, …),
- VM diagnostics such as
  `The debug library is required on Luau platforms. Please open a support ticket.`,
- `Luraph Decompression Error: ` in the KX main payload.

They do **not** contain:

- the runtime configuration,
- plaintext API keys,
- the final Prison Life feature list,
- any server-side code.

This is expected: Luraph encrypts the constant table and decrypts it only when
the VM runs. Static string extraction recovers the VM's skeleton, not the
protected program.

---

## 6. Defensive indicators

Domains and paths observed in the loaders:

- `anomaly.pw/prisonlife`
- `anomaly.pw/script`
- `anomaly.pw/mtc4`
- `anomaly.pw/coldwar`
- `anomaly.pw/wartycoon`
- `anomaly.pw` (Discord invite fallback is `discord.gg/auBaHr6juB`)
- `discord.gg/hKYHQJB5SB` (`#buyer-info` key channel in the key-gated stub)
- `kxadminv2.onrender.com/kx-free/loader`
- `kxadminv2.onrender.com/kx-free/assets/094819024ddbe189eaa9d179ae3f5975.lua`
- `raw.githubusercontent.com/Keraunius/213sadd23/refs/heads/main/kxadm.lua`

Hashes for the payloads are in [`../artifacts/README.md`](../artifacts/README.md).
These are indicators for blocking/detection, not proof that every file with the
same hash is malicious in every context.

---

## 7. Open questions

- The KX stage-2 program's final feature set and any runtime endpoints were not
  recovered. The deserializer works; the interpreter's full run is expensive.
- The Anomaly payload's runtime behaviour was not executed to completion. Its
  static table identifies the VM, not the feature set.
- The relationship between the Anomaly and KX operators is unknown. Both use
  the same obfuscator version and the same VM library, which suggests a common
  toolchain, not necessarily a common author.

These are stated as open questions rather than guessed answers.
