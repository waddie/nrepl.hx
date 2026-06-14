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
(define version "0.2.3")

;; Pure-Scheme dependencies (the nREPL client is self-contained in the dylib).
(define dependencies '())

(define dylibs
  '((#:name
     "steel_nrepl"
     #:urls
     ((#:platform
       "aarch64-macos"
       #:url
       "https://github.com/waddie/nrepl.hx/releases/download/v0.2.3/libsteel_nrepl-aarch64-macos.dylib")
      (#:platform
       "x86_64-macos"
       #:url
       "https://github.com/waddie/nrepl.hx/releases/download/v0.2.3/libsteel_nrepl-x86_64-macos.dylib")
      (#:platform
       "x86_64-linux"
       #:url
       "https://github.com/waddie/nrepl.hx/releases/download/v0.2.3/libsteel_nrepl-x86_64-linux.so")
      (#:platform
       "x86_64-windows"
       #:url
       "https://github.com/waddie/nrepl.hx/releases/download/v0.2.3/steel_nrepl-x86_64-windows.dll")))))
