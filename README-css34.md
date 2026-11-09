# AntiDLL for CS:S v34

Fork of [JDW1337/AntiDLL](https://github.com/JDW1337/AntiDLL) with builds for CS:S v34
(episode1 / "original" engine, Linux x86). The upstream code is not changed; only the
build is new (`ci/build.sh`, `.github/workflows/css34.yml`).

The upstream 1.4 release binaries were built against SourceMod 1.10:
- SourceMod 1.13 rejects them: "Extension version is too old to load".
- SourceMod 1.7.3 cannot serve them: "Could not find interface: ISourceMod".

| archive | SourceMod | extension | plugin |
|---|---|---|---|
| `antidll-<ver>-sm13-css34-linux.tar.gz` | 1.13 from [sourcemod-css34](https://github.com/fmu1337/sourcemod-css34) | `AntiDLL.ext.2.ep1.so` (ext API 11) | spcomp 1.13 |
| `antidll-<ver>-sm17-css34-linux.tar.gz` | 1.7.3 (1.ep1 core, Metamod 1.10) | `AntiDLL.ext.1.ep1.so` (ext API 8) | spcomp 1.7.3 |

Build notes:
- Toolchain: manylinux2014_i686, GCC 10.2.1, glibc 2.17, static libstdc++/libgcc.
- Exported symbols: only `GetSMExtAPI` and the Metamod entry. On MM 1.12 headers that is `CreateInterface_MMS`; on 1.10 core-legacy it is `CreateInterface`.
- If the Metamod entry is hidden, the load fails with "Function CreateInterface not found".
- On GCC 10 the core-legacy `SMM_API` macro is not default-visible, so the build passes `-DSMM_API=...`.

Install: unpack the archive into `cstrike/`, then run `sm exts load AntiDLL.ext` and `sm plugins load AntiDLL`.
