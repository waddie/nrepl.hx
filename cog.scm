;; Copyright (C) 2025, 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; cog.scm - Forge package manifest for nrepl.hx
;;;
;;; Installable with Steel's package manager:
;;;
;;;   forge pkg install --git https://github.com/waddie/nrepl.hx
;;;
;;; then, in ~/.config/helix/init.scm:
;;;
;;;   (require "nrepl.hx/nrepl.scm")
;;;
;;; Forge copies this directory to ~/.steel/cogs/nrepl.hx/ and downloads the
;;; matching prebuilt dylib (see `dylibs` below) to ~/.steel/native/. The dylib
;;; name "steel_nrepl" gains the platform prefix/extension, producing the
;;; libsteel_nrepl.{dylib,so} / steel_nrepl.dll that core.scm loads via
;;; (#%require-dylib "libsteel_nrepl" ...).
;;;
;;; RELEASING: the URLs below are pinned to a release tag. To cut version X.Y.Z:
;;;   1. Bump `version` here and the workspace version in Cargo.toml to X.Y.Z.
;;;   2. Update every release URL below from the old tag to v X.Y.Z.
;;;   3. Commit, then `git tag vX.Y.Z && git push --tags`.
;;;   4. The release workflow builds the dylibs and attaches them to the release.
;;; The platform strings (aarch64-macos, ...) are `${ARCH}-${OS}` as reported by
;;; Rust's std::env::consts; forge matches them exactly.

(define package-name 'nrepl.hx)
(define version "0.1.4")

;; Pure-Scheme dependencies (the nREPL client is self-contained in the dylib).
(define dependencies '())

(define dylibs
  '((#:name
     "steel_nrepl"
     #:urls
     ((#:platform
       "aarch64-macos"
       #:url
       "https://github.com/waddie/nrepl.hx/releases/download/v0.1.4/libsteel_nrepl-aarch64-macos.dylib")
      (#:platform
       "x86_64-macos"
       #:url
       "https://github.com/waddie/nrepl.hx/releases/download/v0.1.4/libsteel_nrepl-x86_64-macos.dylib")
      (#:platform
       "x86_64-linux"
       #:url
       "https://github.com/waddie/nrepl.hx/releases/download/v0.1.4/libsteel_nrepl-x86_64-linux.so")
      (#:platform
       "x86_64-windows"
       #:url
       "https://github.com/waddie/nrepl.hx/releases/download/v0.1.4/steel_nrepl-x86_64-windows.dll")))))
