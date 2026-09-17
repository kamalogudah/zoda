# Zoda — Platform and Toolchain

**Status:** Adopted  
**Date:** 2026-09-17  
**Relates to:** [ADR-0001: Zoda](zoda_plan.md), Phase A (§4, §6)

This file pins the exact toolchain and documents the supported platform,
installation steps, clean-checkout validation commands, and the allocator and
threading assumptions the project is built on. Phase A of ADR-0001 requires an
exact, reproducible compiler pin; the `minimum_zig_version` field in
`build.zig.zon` expresses a floor, not a pin, so the pin lives here and is
enforced by CI.

## 1. Pinned compiler

The exact compiler version Zoda is developed and tested against:

| | |
|---|---|
| **Zig version** | `0.16.0` |
| **Release date** | 2026-04-13 |
| **Notes** | [ziglang.org release notes](https://ziglang.org/download/0.16.0/) |

This is an exact, reproducible pin. Toolchain upgrades are deliberate
decisions: update this file and the CI workflow, and validate that a clean
checkout still passes before merging an upgrade. The build.zig.zon
`minimum_zig_version = "0.16.0"` remains the compatibility floor and must never
exceed the pinned version.

## 2. Supported platform

**Primary supported target:** `x86_64-linux-gnu`.

The reference development and CI environment is Ubuntu 24.04 LTS
(`x86_64-linux-gnu`, glibc 2.39+). CI runs the pinned compiler on
`ubuntu-latest`; see `.github/workflows/ci.yml`.

Other targets are best-effort only and are not CI-covered: no guarantees are
made for macOS, Windows, other architectures, or musl builds until a later
ADR extends the support matrix.

## 3. Installing the pinned compiler

Download tarballs are published at
[ziglang.org/download/0.16.0](https://ziglang.org/download/0.16.0/).

**Primary method — official tarball (`x86_64-linux`):**

```sh
curl -fL -o zig.tar.xz \
  https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
echo "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00  zig.tar.xz" | sha256sum -c
tar -xf zig.tar.xz
export PATH="$PWD/zig-x86_64-linux-0.16.0:$PATH"
```

**Alternative methods** (must still report `zig version` → `0.16.0`):

- Snap: `sudo snap install zig --channel=0.16/beta` (classic confinement)
- Homebrew (on Linux): `brew install zig@0.16.0`

Verify before use:

```sh
zig version   # must print exactly: 0.16.0
```

## 4. Clean-checkout validation

From a fresh clone with the pinned compiler on the primary platform, the
following must all pass:

```sh
zig version                 # 0.16.0
zig fmt --check build.zig src
zig build                   # compiles the library, executable, and tests
zig build test              # runs library + executable test suites
./zig-out/bin/zoda          # smoke-run the demo executable
```

Guidance:

- Run `zig build` from the repository root; `zig build test` builds and runs
  both the library (`src/root.zig`) and executable (`src/main.zig`) test
  suites.
- `zig fmt --check` is the formatter gate enforced by CI. Use `zig fmt` to
  format before committing.
- `.zig-cache/` and `zig-out/` are local build output and must not be
  committed (see `.gitignore`).

### 4.1 How implementation and acceptance tests join CI

The workflow in `.github/workflows/ci.yml` runs on every push to `main` and
on every pull request, so ordinary Phase 0–5 work joins CI automatically:

- **Formatting.** `zig fmt --check build.zig src` gates `build.zig` and every
  file under `src/`. New implementation files are format-checked with no
  workflow edits.
- **Build.** `zig build` compiles the library (`src/root.zig`) and the `zoda`
  executable (`src/main.zig`) and installs `zig-out/bin/zoda`.
- **Unit and acceptance tests.** `zig build test` compiles and runs every
  `test` block reachable from `src/root.zig` and `src/main.zig`, including
  files those roots `@import`. Add tests as `test` blocks in `src/` and they
  run on the next push with no workflow change.

When a phase introduces a verification command that is not one of the above —
real-socket integration tests (Phase 2), repeatable load tests (Phase 2b), or
another bespoke acceptance harness — add the exact command to
`.github/workflows/ci.yml`, record it in §4, and record the passing run in §7
before marking that phase complete (ADR §6). Keep the pinned version in
`ci.yml`, `build.zig.zon`, and §1 in sync whenever the toolchain moves.

## 5. Allocator assumptions

Allocation behavior is a public contract, not an implementation detail:

- **Request arena.** Each request owns its storage arena. The caller keeps the
  request alive until `dispatch` returns, and returned capture slices never
  outlive the request (ADR §3.4). Allocation failures during request
  construction propagate as errors, never as "no route matched" (§3.1).
- **Response allocator.** The response owns its body and header copies and is
  allocated from an explicitly supplied response allocator. That allocator
  must outlive the response, must support concurrent use when the application
  serves concurrent requests (or be isolated per request), and the caller calls
  `res.deinit()` after sending (§3.4).
- **Request state.** Per-request plugin state is initialized in declaration
  order and cleaned up in reverse order, including on partial-init failure.
  Cleanup is infallible and never writes a response (§3.2).
- **No hidden allocation.** Zoda follows Zig's no-hidden-allocation principle;
  every allocation is explicit and owned by a documented allocator.

## 6. Threading assumptions

- **Connection model.** Serving uses bounded concurrent connection
  tasks/workers, capped at 128. Each connection processes requests
  sequentially with independent request storage; the accept loop must not
  block on any client finishing a request (ADR Phase 2).
- **Immutable plugins.** Plugin instances are immutable during dispatch; the
  app owns them and their configuration for its lifetime. Any external shared
  mutable resource must provide its own synchronization — a `const` pointer
  does not imply thread safety (§3.2).
- **Middleware frames.** A `Next` continuation frame must not escape or run
  concurrently. Copies of `Next` share one `called` flag; a second call returns
  `error.NextAlreadyCalled`. This lifetime is a caller obligation; Zig does not
  enforce it statically (§3.6).
- **Testing.** Tests use `std.testing.allocator`, which detects leaks and
  double-frees, and the fuzz example uses `std.testing.fuzz`/`std.testing.Smith`
  provided by the pinned compiler.

## 7. Validation evidence

Recorded for Phase A on the primary platform:

- Compiler: `zig version` → `0.16.0` (installed via snap, revision 16117).
- Host: Ubuntu 24.04.4 LTS, kernel 7.0.0-30-generic, `x86_64`.
- `zig build` → success.
- `zig build test` → all tests pass (library + executable suites, including the
  `std.testing.fuzz` example).
- `zig fmt --check build.zig src` → clean.
- `./zig-out/bin/zoda` → exits 0, prints the demo output.
- CI: workflow run
  [35213342849](https://github.com/kamalogudah/zoda/actions/runs/35213342849)
  passes both jobs ("Format check" and "Build and test") on the pinned
  compiler; revalidated locally on a fresh clone (commit `801886b`).

CI (`zig fmt --check`, `zig build`, `zig build test`, plus the `zoda` demo
smoke-run and an exact-version assertion) enforces this on every push and pull
request. See `.github/workflows/ci.yml`.