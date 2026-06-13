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

(define package-name 'nrepl.hx)
(define version "0.2.1")

;; Pure-Scheme dependencies (the nREPL client is self-contained in the dylib).
(define dependencies '())

;; Build a release-asset URL for the current `version`, so bumping `version`
;; above is the only edit needed to retarget every dylib at a new release tag.
(define (dylib-url filename)
  (string-append "https://github.com/waddie/nrepl.hx/releases/download/v"
    version
    "/"
    filename))

(define dylibs
  (list
    (list #:name
      "steel_nrepl"
      #:urls
      (list
        (list
          #:platform
          "aarch64-macos"
          #:url
          (dylib-url "libsteel_nrepl-aarch64-macos.dylib"))
        (list
          #:platform
          "x86_64-macos"
          #:url
          (dylib-url "libsteel_nrepl-x86_64-macos.dylib"))
        (list
          #:platform
          "x86_64-linux"
          #:url
          (dylib-url "libsteel_nrepl-x86_64-linux.so"))
        (list
          #:platform
          "x86_64-windows"
          #:url
          (dylib-url "steel_nrepl-x86_64-windows.dll"))))))
