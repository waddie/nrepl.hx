;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; adapter-utils.scm - Shared Utilities for Language Adapters
;;;
;;; The result/error/output formatting helpers now live in the shared
;;; repl-ui.hx package so they can be reused by other REPL plugins. This module
;;; re-exports them under their original names so the language adapters continue
;;; to require "adapter-utils.scm" unchanged.

(require "repl-ui.hx/format.scm")

(provide take-first-line
  whitespace-only?
  format-error-as-comment
  format-output-list
  format-result-common)
