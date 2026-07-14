;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; test-adapters.scm - pure formatting behavior of the language adapters
;;;
;;; Run from the repo root: steel < tests/test-adapters.scm
;;; Needs repl-ui.hx installed in ~/.steel/cogs (adapter-utils re-exports it).

(require "tests/harness.scm")
(require "cogs/nrepl/adapter-interface.scm")
(require "cogs/nrepl/generic.scm")
(require "cogs/nrepl/clojure.scm")
(require "cogs/nrepl/janet.scm")

;;;; Generic adapter ;;;;

(define generic (make-generic-adapter))

(check-equal! "generic language name" (adapter-language-name generic) "Generic nREPL")
(check-equal! "generic comment prefix" (adapter-comment-prefix generic) ";;")
(check-equal! "generic prompt with ns"
  (adapter-format-prompt generic "user" "(+ 1 2)" 3)
  "user=> (+ 1 2)\n")
(check-equal! "generic prompt without ns"
  (adapter-format-prompt generic #f "(+ 1 2)" 3)
  "=> (+ 1 2)\n")
(check-equal! "generic prettify keeps first line"
  (adapter-prettify-error generic "boom\ndetails\nmore")
  "boom")
(check-false! "generic jack-in unsupported" (adapter-jack-in-cmd generic #f 12345))

;;;; Clojure adapter ;;;;

(define clojure (make-clojure-adapter))

(check-equal! "clojure comment prefix" (adapter-comment-prefix clojure) ";;")
(check-equal! "clojure prompt with ns"
  (adapter-format-prompt clojure "my.ns" "(inc 1)" #f)
  "my.ns=> (inc 1)\n")
(check-equal! "clojure arity error prettified"
  (adapter-prettify-error clojure
    "Execution error (ArityException) at test.core/eval123 (REPL:1).")
  "Arity error - Wrong number of arguments")
(check-equal! "clojure class cast error prettified"
  (adapter-prettify-error clojure
    "Execution error (ClassCastException) at test.core (REPL:1).")
  "Type error - Cannot cast value to expected type")

;;;; Janet adapter ;;;;

(define janet (make-janet-adapter))

(check-equal! "janet comment prefix" (adapter-comment-prefix janet) "#")
(check-equal! "janet file extensions" (adapter-file-extensions janet) '(".janet" ".jdn"))
(check-equal! "janet numbered prompt"
  (adapter-format-prompt janet #f "(+ 1 2)" 3)
  "repl:3:> (+ 1 2)\n")
(check-equal! "janet unnumbered prompt"
  (adapter-format-prompt janet #f "(+ 1 2)" #f)
  "repl:> (+ 1 2)\n")
(check-equal! "janet drops error: prefix"
  (adapter-prettify-error janet "error: unknown symbol foobar\n  in thunk")
  "unknown symbol foobar")
(check-equal! "janet method error canned"
  (adapter-prettify-error janet "error: could not find method :+ for 1")
  "Type error - no matching method for arguments")
(check-equal! "janet parse error canned"
  (adapter-prettify-error janet "error: unexpected end of source, ( opened at line 1")
  "Syntax error - malformed expression")

;;;; format-result via the adapter protocol ;;;;

;; A successful eval with output: prompt, output, then value.
(check-equal! "generic format-result success"
  (adapter-format-result generic "(+ 1 2)"
    (hash 'value "3" 'output (list "hi\n") 'error #f 'ns "user"))
  "user=> (+ 1 2)\nhi\n3\n\n")

(summarize! "adapters")
