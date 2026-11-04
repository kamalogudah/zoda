# Changelog

All notable changes to Zoda are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- **Toolchain upgraded to Zig 0.17.1**, the latest stable release. This is
  now the exact pin and the `minimum_zig_version` floor. Zig 0.16.0 is no
  longer supported. Updated in `build.zig.zon`, CI, `PLATFORM.md`,
  `README.md`, `Getting_started_with_zoda.md`, and
  `examples/inertia/README.md`.
- `build.zig`: `zig build run -- …` and the `run-inertia` and `watch` steps now
  forward arguments with `Step.Run.addPassthruArgs()`, because `b.args` was
  removed. The `watch` step always passes `--`. With no arguments after it, the
  demo still defaults to `serve`.
- `build.zig`: the dev-loop test gets `repo_root` through
  `Options.addOptionPathUntracked`, because `b.pathFromRoot` was removed.
- Comptime reflection in `app.zig`, `template.zig`, and the Inertia plugin now
  iterates `@typeInfo(T).@"struct".field_names` and `field_types` directly,
  because `std.meta.fields` was removed and `Type.Struct.fields` was split
  into parallel slices. The remaining 0.17 reflection renames also apply:
  `StructField.Attributes` is now `Type.Struct.FieldAttributes`,
  `Fn.params` is now `Fn.param_types`, and `Pointer.is_const` is now
  `Pointer.attrs.@"const"`.
- Zig 0.17 removed the `**` array-repeat operator. Repeated strings in tests
  and examples now use `&comptime @as([N]u8, @splat(c))`, and the Inertia tests
  use a small comptime `repeatStr` helper for multi-character patterns.
- `zig fmt` migrations: `@intFromEnum` is now `@backingInt`, `@enumFromInt` is
  now `@fromBackingInt`, and `std.ascii.indexOfIgnoreCase` is now `findIgnoreCase`.

### Added

- `router.Method.query`: requests that use the HTTP `QUERY` method
  ([RFC 10008](https://datatracker.ietf.org/doc/html/rfc10008)) now reach
  routes. Zig 0.17's `std.http.Method` added this method. Like `POST`, a QUERY
  request carries a body, and Inertia redirects after one use `303 See Other`.
  Routes match it explicitly with `req.method == .query`. Zoda does not fall
  back to a GET route for QUERY requests.
  **Breaking:** an exhaustive `switch` on `router.Method` in application code
  needs a `.query` arm or an `else` arm.
