# hellopay

A fake CLI for practising releases. Not a real product.

## Install

```sh
npm install --save-dev hellopay@0.1.2
npx hellopay version
```

Always pin the version. `hellopay@latest` and a bare `npx hellopay` resolve to whatever
is current at that moment, which is the opposite of what a lockfile is for.

In CI, install from the lockfile and leave install scripts off:

```sh
npm ci --ignore-scripts
npx hellopay version
```

This package ships no install scripts at all, so `--ignore-scripts` costs you nothing
here — and it keeps the flag meaningful for every other dependency in your tree.

## How it works

`hellopay` contains no binary. It declares six optional dependencies — one per
platform — and npm installs only the one that matches your machine:

| Platform | Package |
|---|---|
| macOS Intel | `@hellopay/cli-darwin-x64` |
| macOS Apple silicon | `@hellopay/cli-darwin-arm64` |
| Linux x86-64 | `@hellopay/cli-linux-x64` |
| Linux arm64 | `@hellopay/cli-linux-arm64` |
| Windows x86-64 | `@hellopay/cli-win32-x64` |
| Windows arm64 | `@hellopay/cli-win32-arm64` |

Before running the binary, `hellopay` checks its SHA-256 against a table built into
this package and refuses to run on a mismatch.

## Verifying where this package came from

Two steps. There is no badge to trust instead.

```sh
npm audit signatures
npm view hellopay repository.url
```

The second command must print `github.com/hoanghuydev/hellopay`. "Has provenance"
only means *some* repository built it — anyone who takes over a package name can
publish with full provenance from their own repository, and the check still passes.
The repository name is the part that carries the meaning.

## Known limitations of this channel

- **No shell completions.** They need an install script, and this package
  deliberately has none. Use the shell installer or Homebrew if you want them.
- **Weaker verification than the shell installer.** `install.sh` checks a cosign
  signature over `checksums.txt`. npm has no equivalent at install time. See
  `HUONG-DAN-PHAT-HANH-CLI.md` §5.9.4.
- **`--no-optional` / `--omit=optional` breaks it.** The binary lives in an optional
  dependency; skipping those skips the binary. The error message tells you so.

## Other ways to install

<https://github.com/hoanghuydev/hellopay>

MIT
