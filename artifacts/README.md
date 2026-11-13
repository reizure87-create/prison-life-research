# Artifact Manifest

The large obfuscated payloads are **not** committed to this repository. They
are third-party works, and the research only needs their hashes plus the small
extracted-constant files. Verify an artifact with:

```sh
sha256sum <file>
```

## Core payloads (not committed)

| Artifact | Size (bytes) | SHA-256 |
|---|---:|---|
| `anomaly_pl.lua` | 552,365 | `3f4e33416dc7999d4e8d14e4f402c9400c893cd617d8bbe14bb0c1b776845673` |
| `anomaly_pl_clean.lua` | 583,207 | `a7ffda61de49b4f2880a8cf70e79a92d29a432c6a81c40a0148688119a2baade` |
| `kx_main.lua` | 3,029,622 | `2787c672c244da18ad7be0901957e62280429aad608ef71135fb90d0983d4946` |
| `kx_stage2_vm_clean.luajit.lua` | 224,062 | `0aeed49883eb503b0defdbe195f0d82ed41263f3fc7970cca17a2df6fb8f40d7` |
| `kx_stage2_data_clean.bin` | 2,354,258 | `a04e7555201ad773929531147e416ff8a0a8c6fad6cfbb672f4229e8e36d8eac` |

The stage-2 VM and blob are the extracted pair used in
[`../docs/Anomaly-and-KX.md`](../docs/Anomaly-and-KX.md). The payloads are
Luraph Obfuscator v15.1 output.

## Recovered reference (committed)

| Artifact | Size (bytes) | SHA-256 |
|---|---:|---|
| `../docs/PrisonLife-Deobfuscated-API.md` | 47,578 | `81f9f876692efdb3ff2306b23600da0d6f4e4729929c7a9d884e0bb58625fcc1` |

The hash is of the source document before the rename; the content is otherwise
unchanged.

## Loaders (committed)

| Artifact | Size (bytes) | SHA-256 |
|---|---:|---|
| `../loaders/anomaly_loader.lua` | 525 | `bba419c44d6577273f9d81e2ce37150fe2098345e29a75ab772ccbed20a69a5f` |
| `../loaders/kx_loader.lua` | 208 | `b07846c54b678817d04f42a1b957647ea9f3bfd3f25abf248bbbe5b66d6fc205` |
| `../loaders/kxadm.lua` | 77 | `55d2ad83e4198d6424af94d463b64df8dddec1b6a3e648471b790e3c433951c8` |

## Comparison scripts (not committed)

These were used for cross-checking remote names and feature expectations. They
are public third-party scripts and are not redistributed here.

| Artifact | Size (bytes) | SHA-256 |
|---|---:|---|
| `PrisonLifeHvH.lua` (PrisonX v1.24 by TS2021) | 97,242 | `b472c78cda9cfb2ed992b3896286af7f3287abbaba69624fa81e6e3a96c92bc6` |
| `Vape_155615604.lua` | 107,845 | `aa142a1b66f4bf98baa263ea09d58437528c93c0c7ba10d44d840cc1328abd0c` |
| `ScriptWorks-235771.lua.decoded.txt` | 70,876 | `459d7a6d5ef2b351abf47ff241823cdac93ec9a3e8044781eb7fc0ee9511dbc8` |

## Source archive

The analysis was performed against the research archive that accompanied this
project (`pl_research_active.zip`, extracted to a scratch directory). The
archive is not committed. If you are reproducing the work, obtain the payloads
separately and check the hashes above before running any harness.

## What is deliberately absent

- Licence keys, tokens, cookies, and account identifiers.
- Server-side game code (it is not present in a client dump).
- The full `anomaly_pl.lua` / `kx_main.lua` / stage-2 blob bytes.
- Any working exploit or key-bypass logic.

If a hash does not match, do not run the file; treat the copy as unverified.
