# Tools

Two small utilities used to analyse the Luraph v15.1 payloads and the nested KX
stage-2 VM.

---

## `run_vm.lua`

Deserializes a dumped stage-2 VM against a dumped encrypted blob. It runs under
**LuaJIT 2.1+** and needs no Roblox client: the Roblox surface (`game`,
`Instance`, `Vector3`, `CFrame`, `Color3`, `UDim2`, `task`, `debug`, …) is
mocked, and every external call is logged.

```sh
luajit tools/run_vm.lua <vm.lua> <data.bin> [probe]
```

- `<vm.lua>` — the dumped VM chunk, normally
  `kx_stage2_vm_clean.luajit.lua`.
- `<data.bin>` — the encrypted blob, normally `kx_stage2_data_clean.bin`.
- `probe` — optional. Stops after building the VM table and reports any numeric
  dependency slots that are `nil`. This is how slot `[2] = table.pack` was
  identified.

Expected start of a successful run:

```text
[load] vm=224062 data=2354258
[loadstring] kx_stage2_vm len=224062
[deserialize] ok=true type=function val=function: 0x...
```

The deserializer returns a callable function. Running it is CPU-bound: the VM
then interprets a 2.35 MB encrypted program. The script passes the function to
`pcall` and logs strings as they are produced; a full run is not needed to
recover the client API.

### Polyfills and gotchas

Stock LuaJIT 2.1 is Lua 5.1 plus extensions. The VM expects Luau:

| Provided | Reason |
|---|---|
| `table.pack`, `table.create`, `table.clear`, `table.clone` | Luau table library |
| `table.move` | Lua 5.3+; Lua 5.1 lacks it |
| `coroutine.close`, `coroutine.isyieldable` | Luau coroutine API |
| `typeof`, `vector.create`, `buffer.*`, `bit32.*` | Roblox/Luau globals |
| `string.pack`, `string.unpack` | Lua 5.3+; implemented here for the Luau formats (`i/I`, `f`, `d`, `n`, `c`, `s`, `z`, `x`) |
| `setfenv` wrapper | the VM probes C functions; stock `setfenv` errors on them |
| `debug.info` mock | the VM uses it to classify functions |

The critical detail: **slot `[2]` is `table.pack`, not `buffer.fromstring`.**
With `buffer.fromstring` the packed varargs become the 2.35 MB buffer and
`unpack` fails with `too many results to unpack`. That error is a harness bug,
not a corrupt payload.

`unpack` is wrapped to log calls with more than 1,000 values, because LuaJIT
caps results at 8,000; the wrapper prints the caller and locals so a bad
dependency slot is diagnosable.

---

## `transpile_luau.py`

Rewrites Luau-only syntax into LuaJIT-loadable Lua: compound assignments,
`//` floor division, and Luau's `if … then … else …` expressions. It was used to
turn the dumped VM into `kx_stage2_vm_clean.luajit.lua`.

```sh
python3 tools/transpile_luau.py input.lua output.luajit.lua
```

It prints a summary:

```text
Transpiled input.lua -> output.luajit.lua: expr_if=…, fdiv=…, comp=…
```

The parser asserts that every token was consumed, so a partially converted file
fails loudly instead of producing silently wrong output. It does not attempt to
reconstruct Luau type annotations (Luraph v15.1 does not emit them).

---

## Reproducing the hashes

The VM and blob are **not** committed. Obtain them from the original research
archive and check them against [`../artifacts/README.md`](../artifacts/README.md)
before running anything:

```sh
sha256sum kx_stage2_vm_clean.luajit.lua kx_stage2_data_clean.bin
```

Expected:

```text
0aeed49883eb503b0defdbe195f0d82ed41263f3fc7970cca17a2df6fb8f40d7  kx_stage2_vm_clean.luajit.lua
a04e7555201ad773929531147e416ff8a0a8c6fad6cfbb672f4229e8e36d8eac  kx_stage2_data_clean.bin
```
