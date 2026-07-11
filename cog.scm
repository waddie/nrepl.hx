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
(define version "0.3.2")

;; ui-utils.hx: the shared Helix/Steel UI library supplying the picker and
;; overlay drawing primitives. run-command: the subprocess-running library used
;; for every jack-in shell-out (lsof/find/kill). The nREPL client itself is
;; self-contained in the dylib.
(define dependencies
  '((#:name "ui-utils.hx"
     #:git-url
     "https://github.com/waddie/ui-utils.hx"
     #:sha
     "2998d8229330e433e483745fc8750702b8d134e4")
    (#:name "run-command"
     #:git-url
     "https://github.com/waddie/run-command.scm"
     #:sha
     "ed42a376c4761e10530981c34797e7dde8e5abef")
    (#:name "repl-ui.hx"
     #:git-url
     "https://github.com/waddie/repl-ui.hx"
     #:sha
     "8d21aee4114222f0ce708d1c146598a1ce7ae621")))

(define dylibs
  '((#:name
     "steel_nrepl"
     #:urls
     ((#:platform
       "aarch64-macos"
       #:url
       "https://github.com/waddie/nrepl.hx/releases/download/v0.3.2/libsteel_nrepl-aarch64-macos.dylib")
      (#:platform
       "x86_64-macos"
       #:url
       "https://github.com/waddie/nrepl.hx/releases/download/v0.3.2/libsteel_nrepl-x86_64-macos.dylib")
      (#:platform
       "x86_64-linux"
       #:url
       "https://github.com/waddie/nrepl.hx/releases/download/v0.3.2/libsteel_nrepl-x86_64-linux.so")
      (#:platform
       "x86_64-windows"
       #:url
       "https://github.com/waddie/nrepl.hx/releases/download/v0.3.2/steel_nrepl-x86_64-windows.dll")))))
