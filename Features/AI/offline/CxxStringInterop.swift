//
//  CxxStringInterop.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Version-agnostic `std::string` → Swift `String` conversion.
//
//  Linking LLM.swift (llama.cpp, a C++ module) shifts the app target's C++ interop so the
//  `CHoshiDicts` `std::string` fields import as the libc++ *versioned* type `std.__1.string`
//  instead of `std.string`. The `CxxStdlib` overlay's `String(_:)` initializer is declared over
//  `std.string`, so the plain `String(cxxString)` call stops resolving in some files. This helper
//  converts via the interop's own NUL-terminated buffer accessor, which is stable across that
//  versioned-namespace difference, so existing dictionary-style call sites keep working.
//

import CxxStdlib

/// Converts an interop `std::string` to a Swift `String`. Resilient to the libc++ versioned
/// namespace (`std.__1.string`) the way `String(cxxString:)` is not under mixed C++ interop.
@inline(__always)
func cxxStringToSwift(_ cxxString: std.string) -> String {
    String(cxxString)
}
