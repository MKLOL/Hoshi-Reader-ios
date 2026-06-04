//
//  CxxStringInterop.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Centralizes `std::string` → Swift `String` conversion for the few call sites where the plain
//  `String(_:)` overload from the `CxxStdlib` overlay fails to resolve.
//
//  Most files convert `CHoshiDicts` `std::string` fields with a bare `String(cxxString)`. In
//  `ReaderViewModel.swift`, however, that exact call stops type-checking ("no exact matches in call
//  to initializer") — the file's particular C++ interop import graph resolves the libc++ string to a
//  type the `CxxStdlib` overlay's `String(_:)` initializer isn't declared over at the call site.
//
//  The conversion *does* resolve here in this file, whose import graph leaves the canonical
//  `std.string` namespace intact. Routing those call sites through this helper keeps them compiling
//  without sprinkling per-site workarounds, and gives one obvious place to revisit if a future
//  toolchain makes `String(_:)` resolve uniformly everywhere (at which point this can be deleted and
//  the call sites reverted to plain `String(...)`).
//

import CxxStdlib

/// Converts an interop `std::string` to a Swift `String`. Use at the call sites where the plain
/// `String(cxxString)` overload doesn't resolve under this target's mixed C++ interop (see the
/// file header); elsewhere `String(...)` is fine.
@inline(__always)
func cxxStringToSwift(_ cxxString: std.string) -> String {
    String(cxxString)
}
