# Methodology

This page describes how the results in this repository were produced, what
could and could not be verified, and how to reproduce the work.

## 1. Sources

| Source | What it is | Used for |
|---|---|---|
| `Prison life dumped` | Client-side script dump of PlaceId `155615604` | Remote names, script constants, item/gun/team behaviour |
| ScriptBlox listings `234648`, `235599`, `235771`, `230831`, `235397` | Public script catalogue entries | Loader stubs, comparison scripts, obfuscation samples |
| `anomaly.pw` / `kxadminv2.onrender.com` loader stubs | Small Lua files distributed with the scripts | Route tables and loader chains |
| Luraph-protected payloads | `anomaly_pl.lua`, `kx_main.lua` | Protection identification, stage-2 extraction |
| Open-source Prison Life scripts (`PrisonLifeHvH.lua`, etc.) | Public scripts | Cross-checking remote names and feature expectations |

The client dump is the authoritative source for the API reference. It is a dump
of **client-reachable** scripts only. Roblox does not replicate
`ServerScriptService` or `ServerStorage` to clients, so server validation logic
is absent by construction, not by a failure of the extraction.

## 2. Recovering the client API

The dump stores each script as hex-encoded Luau **bytecode**, not source. The
recovery pipeline was:

1. **Decode** each script's bytecode container and locate its constant table.
2. **Extract every string constant**. Remote names, method names, item names,
   team names, asset ids, and error messages all live in the constant table.
3. **Group by script path** to preserve the call-site context. A constant such
   as `ArrestPlayer` next to `InvokeServer` and `HandcuffsClient` is strong
   evidence for an arrest remote; the same string in an unrelated module would
   not be.
4. **Cross-check** remote names against the calling scripts and against public
   scripts that use the same remotes.
5. **Mark inference**. The remote name and its call syntax are confirmed; the
   meaning of each argument is inferred from the caller. The API reference
   states this explicitly.

Bytecode-to-source decompilation was not attempted by hand. The result is a
constant-and-context reference, not reconstructed source. This is sufficient to
build or audit scripts against the real remote names, which is the practical
goal.

Counts from the dump: 103 scripts, comprising 54 `LocalScript`, 19 `Script`
(client/shared `RunContext`), and 30 `ModuleScript`. Of those, 93 have at least
one recoverable string constant and therefore get a per-script section
(49 `LocalScript`, 19 `Script`, 25 `ModuleScript`); the other 10 contain no
extractable strings and appear only in the aggregate count.

## 3. Identifying the obfuscator

Both large payloads begin with the same comment:

```lua
-- This file was protected using Luraph Obfuscator v15.1 [https://lura.ph/]
```

This is a direct identification. The extracted string tables independently
confirm it: they contain the Luraph VM's standard-library list, its ASCII-art
banner, and diagnostics such as:

```text
The debug library is required on Luau platforms. Please open a support ticket.
Luraph Decompression Error:
```

The VM structure is consistent with Luraph v15.1: a `return setmetatable({...},
{}):entry(...)` expression, a numeric dependency table binding Luau globals,
and an interpreter loop over encrypted bytecode.

## 4. Extracting the KX stage-2 VM

The KX main payload is a Luraph-protected script that itself contains a nested
VM and a large encrypted blob. The extraction steps were:

1. Transpile the Luau-flavoured source to LuaJIT-compatible Lua
   (`tools/transpile_luau.py`).
2. Load the main payload in a sandbox with mocked Roblox globals.
3. Identify the nested VM chunk (`return setmetatable({...},{})`) and the blob
   it consumes.
4. Write the VM chunk to `kx_stage2_vm_clean.luajit.lua` and the blob to
   `kx_stage2_data_clean.bin`.
5. Run the VM with `tools/run_vm.lua`.

The extraction is deterministic: the same input payload produces the same VM
and blob bytes, and the manifest records their hashes.

## 5. Deserializing the stage-2 VM

The first attempts failed for environmental reasons, not because the payload
was corrupt. The important steps were:

1. **Provide LuaJIT's missing Luau globals.** `table.pack`, `table.create`,
   `table.clear`, `coroutine.close`, `coroutine.isyieldable`, `typeof`,
   `vector`, `buffer`, and `bit32` are not all present in stock LuaJIT 2.1.
2. **Get the dependency-slot semantics right.** Slot `[2]` is `table.pack`.
   An earlier shim set it to `buffer.fromstring`, which turned the packed
   varargs into the 2.35 MB buffer and produced a misleading
   `too many results to unpack` error. With `table.pack`, `yS` unpacks exactly
   one value and the interpreter proceeds.
3. **Mock only the host surface.** The VM needs `game`, `Instance`, `Vector3`,
   `CFrame`, `Color3`, `UDim2`, `task`, `debug`, and similar globals, but it
   does not need a real Roblox client. The mocks log every call so the
   analysis can see what the payload asks for.

The result is reproducible:

```text
[load] vm=224062 data=2354258
[deserialize] ok=true type=function ...
```

## 6. Confirmed vs. inferred

The documents use two labels deliberately:

- **Confirmed** — reproduced from bytes or a runtime result: a URL, a hash, a
  header comment, a loader path, a script count, a remote name, a
  `[deserialize] ok=true` line.
- **Inferred** — a reading of context: what a remote argument means, why a
  branch exists, who wrote a payload, what a decrypted string will be used for.

Where a claim could not be verified, it is listed as an open question instead
of being smoothed over. In particular:

- The KX stage-2 program's runtime feature set was not recovered.
- The Anomaly payload's runtime behaviour was not executed to completion.
- Authorship and operator relationships are unknown.

## 7. Limits

- **No server code.** A client dump cannot contain it. The remote list is the
  complete client-visible server surface.
- **No full source reconstruction.** Luau bytecode is not decompiled to
  high-level source here; the reference is built from constants and context.
- **Runtime cost.** The KX stage-2 interpreter is CPU-bound on the test host.
  Deserialization is fast; full execution is not. The capture harness records
  strings as they are produced, but a complete run was not required for the
  API reference.
- **Third-party payloads.** The large obfuscated files are not committed. The
  manifest gives hashes so the analysis can be reproduced from the original
  archive.

## 8. Reproducibility checklist

- [x] Client script counts and paths recorded.
- [x] Remote names extracted and grouped by caller.
- [x] Loader URLs and route table transcribed verbatim.
- [x] Luraph version identified from the header and VM strings.
- [x] Payload sizes and SHA-256 hashes recorded.
- [x] Stage-2 VM deserialization reproduced under LuaJIT.
- [x] Harness and transpiler included.
- [ ] KX stage-2 full execution completed (open; see
      [`Anomaly-and-KX.md`](Anomaly-and-KX.md)).
- [ ] Anomaly full execution completed (open).

The unchecked items are honest limitations, not silent omissions.
