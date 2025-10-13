;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; adapter-interface.scm - Language Adapter Protocol
;;;
;;; Defines the standard interface that all nREPL language adapters must implement.
;;; Each language (=Helix language identifier e.g. 'clojure') provides its own adapter
;;; that handles language-specific concerns like error formatting, prompt styling,
;;; and syntax conventions.

;; Provide struct and helper functions
;; Note: Steel automatically generates accessors for struct fields:
;;   adapter-prettify-error-fn, adapter-format-prompt-fn, adapter-format-result-fn,
;;   adapter-language-name, adapter-file-extensions, adapter-comment-prefix
(provide adapter
         adapter?
         make-adapter
         adapter-prettify-error
         adapter-format-prompt
         adapter-format-result
         ;; Auto-generated accessors needed by core.scm
         adapter-prettify-error-fn
         adapter-format-prompt-fn
         adapter-format-result-fn
         adapter-language-name
         adapter-file-extensions
         adapter-comment-prefix)

;;; Adapter Structure ;;;

;; Base adapter struct holding function implementations
;; Steel automatically generates accessor functions for each field
(struct adapter
        (prettify-error-fn ; (string?) -> string?
         format-prompt-fn ; (or/c string? #f) (string?) -> string?
         format-result-fn ; (string?) (hash?) -> string?
         language-name ; string?
         file-extensions ; (list string?)
         comment-prefix) ; string?
  #:transparent)

;;; Adapter Constructor ;;;

;;@doc
;; Create a new language adapter with required implementations
;;
;; Parameters:
;;   prettify-error-fn  - Function: (err-str) -> prettified-str
;;   format-prompt-fn   - Function: (namespace code) -> formatted-prompt
;;   format-result-fn   - Function: (code result-hash) -> formatted-output
;;   language-name      - String: Human-readable language name
;;   file-extensions    - List of strings: File extensions (e.g., '(".clj" ".cljc"))
;;   comment-prefix     - String: Comment prefix for this language (e.g., ";;")
;;
;; Returns:
;;   adapter struct with auto-generated accessors
(define (make-adapter prettify-error-fn
                      format-prompt-fn
                      format-result-fn
                      language-name
                      file-extensions
                      comment-prefix)
  (adapter prettify-error-fn
           format-prompt-fn
           format-result-fn
           language-name
           file-extensions
           comment-prefix))

;;; Adapter Interface Functions ;;;

;;@doc
;; Transform verbose error messages into concise, language-specific format
;;
;; Examples:
;;   Clojure: "Execution error (ArityException)..." -> "Arity error - Wrong number of arguments"
;;   Generic: Multi-line error -> First line only
(define (adapter-prettify-error adapter err-str)
  ((adapter-prettify-error-fn adapter) err-str))

;;@doc
;; Format the REPL prompt with optional namespace
;;
;; Examples:
;;   Clojure: (adapter-format-prompt adapter "user" "(+ 1 2)") -> "user=> (+ 1 2)\n"
;;   Generic: (adapter-format-prompt adapter #f "(+ 1 2)") -> "=> (+ 1 2)\n"
(define (adapter-format-prompt adapter namespace code)
  ((adapter-format-prompt-fn adapter) namespace code))

;;@doc
;; Format the complete evaluation result for display in *nrepl* buffer
;;
;; Takes:
;;   code        - The code that was evaluated
;;   result      - Hash with keys: 'value 'output 'error 'ns
;;
;; Returns:
;;   Formatted string with prompt, output, errors, and value
(define (adapter-format-result adapter code result)
  ((adapter-format-result-fn adapter) code result))
