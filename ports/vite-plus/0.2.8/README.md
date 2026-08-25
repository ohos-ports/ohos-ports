# vite-plus 0.2.8 — OpenHarmony repack

[vite-plus](https://viteplus.dev) publishes no openharmony platform package
for its main napi binding. This port builds the binding **from source** and
repacks the official npm tarball with it embedded, published as
**@ohos-ports/vite-plus** (`0.2.8-1`).

The upstream loader (`binding/index.cjs`) already has an `openharmony`/`arm64`
branch that tries `./vite-plus.openharmony-arm64.node` first, so the repacked
package needs no loader patch and no postinstall wiring.

## Not covered here (use upstream instead)

- **rolldown binding**: official `@rolldown/binding-openharmony-arm64`
  ships native OHOS support — depend on it directly.
- **lightningcss**: see the `lightningcss` port in this repo.

## Consuming

```json5
{
  "overrides": {
    "vite-plus": "npm:@ohos-ports/vite-plus"
  }
}
```

## Build

`build.sh` uses two trees:

1. **Source tree** (GitHub v0.2.8 tarball): compiles the main napi binding —
   mirrors the homebrew-core formula (stable rust + `RUSTC_BOOTSTRAP=1`,
   pnpm@10, musl-napi injection for yuku-*/@ast-grep/rollup/lightningcss/
   @parcel/watcher), then signs via `binary-sign-tool`.
2. **Official tgz**: unpacked, patched (rename to `@ohos-ports/vite-plus`),
   and the signed binding dropped into `binding/`.

Known gap: `vp lint --type-aware` needs tsgolint, which has no OHOS binary.
