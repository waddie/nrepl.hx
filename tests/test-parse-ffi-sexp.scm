;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; test-parse-ffi-sexp.scm - parse-ffi-sexp against every FFI emitter shape
;;;
;;; The shapes tested here mirror the emitters in
;;; crates/steel-nrepl/src/connection.rs: eval results, need-input, completions,
;;; lookup, describe, ls-sessions, and stats. Run: steel < tests/test-parse-ffi-sexp.scm

(require "tests/harness.scm")
(require (only-in "cogs/nrepl/string-utils.scm" parse-ffi-sexp))

;;;; Eval result hash (eval_result_to_steel_hashmap) ;;;;

(let ([r (parse-ffi-sexp
          "(hash 'value \"3\" 'output (list \"a\" \"b\") 'error #f 'ns \"user\" 'ex #f 'interrupted #f)")])
  (check-true! "eval result parses to a hash" (hash? r))
  (check-equal! "eval result value" (hash-get r 'value) "3")
  (check-equal! "eval result output list" (hash-get r 'output) (list "a" "b"))
  (check-equal! "eval result error" (hash-get r 'error) #f)
  (check-equal! "eval result ns" (hash-get r 'ns) "user")
  (check-equal! "eval result interrupted" (hash-get r 'interrupted) #f))

;; Interrupted flag set
(let ([r (parse-ffi-sexp "(hash 'value #f 'interrupted #t)")])
  (check-equal! "interrupted #t survives" (hash-get r 'interrupted) #t))

;;;; need-input hash (nrepl_try_get_result NeedInput arm) ;;;;

(let ([r (parse-ffi-sexp
          "(hash 'need-input #t 'request-id 7 'output (list \"Your name: \") 'error #f)")])
  (check-equal! "need-input flag" (hash-get r 'need-input) #t)
  (check-equal! "need-input request id is a number" (hash-get r 'request-id) 7)
  (check-equal! "need-input partial output" (hash-get r 'output) (list "Your name: ")))

;;;; Completions (list of hashes with #: keys) ;;;;

(let ([r (parse-ffi-sexp
          "(list (hash '#:candidate \"map\" '#:ns \"clojure.core\" '#:type \"function\") (hash '#:candidate \"mapv\" '#:ns #f '#:type #f))")])
  (check-true! "completions parse to a list" (list? r))
  (check-equal! "completions length" (length r) 2)
  (check-equal! "first candidate" (hash-get (car r) '#:candidate) "map")
  (check-equal! "first candidate ns" (hash-get (car r) '#:ns) "clojure.core")
  (check-equal! "second candidate ns is #f" (hash-get (cadr r) '#:ns) #f))

;;;; Lookup (flat hash with #: keys) ;;;;

(let ([r (parse-ffi-sexp "(hash '#:name \"map\" '#:doc \"docstring here\")")])
  (check-equal! "lookup name" (hash-get r '#:name) "map")
  (check-equal! "lookup doc" (hash-get r '#:doc) "docstring here"))

;;;; Describe (nested hashes, string keys, empty sections) ;;;;

(let ([r (parse-ffi-sexp
          "(hash 'ops (list \"eval\" \"describe\") 'versions (hash \"nrepl\" (hash \"version-string\" \"1.3.0\")) 'aux (hash ))")])
  (check-equal! "describe ops" (hash-get r 'ops) (list "eval" "describe"))
  (check-equal! "describe nested version"
    (hash-get (hash-get (hash-get r 'versions) "nrepl") "version-string")
    "1.3.0")
  (check-equal! "describe empty aux" (hash-get r 'aux) (hash)))

(let ([r (parse-ffi-sexp "(hash 'ops (list ) 'versions (hash ) 'aux (hash ))")])
  (check-equal! "describe empty ops list" (hash-get r 'ops) (list)))

;;;; ls-sessions (flat string list) ;;;;

(check-equal! "ls-sessions list"
  (parse-ffi-sexp "(list \"31f2c0a2-1\" \"31f2c0a2-2\")")
  (list "31f2c0a2-1" "31f2c0a2-2"))

;;;; Stats (numbers, nested list of hashes) ;;;;

(let ([r (parse-ffi-sexp
          "(hash 'total-connections 2 'total-sessions 3 'max-connections 100 'next-conn-id 5 'connections (list (hash 'id 1 'sessions (list \"abc\"))))")])
  (check-equal! "stats total-connections" (hash-get r 'total-connections) 2)
  (check-equal! "stats max-connections" (hash-get r 'max-connections) 100)
  (check-equal! "stats nested session"
    (hash-get (car (hash-get r 'connections)) 'sessions)
    (list "abc")))

;;;; Escaped strings round-trip ;;;;

(let ([r (parse-ffi-sexp "(hash 'value \"quote \\\" backslash \\\\ tab \\t newline \\n end\")")])
  (check-equal! "escapes decode"
    (hash-get r 'value)
    "quote \" backslash \\ tab \t newline \n end"))

;;;; Rejection: nothing outside the grammar may parse (or execute) ;;;;

(define *pwned* (box #f))
(define (pwn!)
  (set-box! *pwned* #t)
  "pwned")

(check-false! "arbitrary call rejected" (parse-ffi-sexp "(system \"id\")"))
(check-false! "call in value position rejected"
  (parse-ffi-sexp "(hash 'value (string-append \"a\" \"b\"))"))
(check-false! "call to local function rejected" (parse-ffi-sexp "(pwn!)"))
(check-false! "local function in value position rejected"
  (parse-ffi-sexp "(hash 'value (pwn!))"))
(check-equal! "payload did not execute" (unbox *pwned*) #f)
(check-false! "unreadable input rejected" (parse-ffi-sexp "not a sexp ("))
(check-false! "bare symbol rejected" (parse-ffi-sexp "some-symbol"))
(check-false! "odd hash arguments rejected" (parse-ffi-sexp "(hash 'value)"))
(check-false! "empty application rejected" (parse-ffi-sexp "()"))

;;;; Quoted symbols pass through as data ;;;;

(check-equal! "quoted symbol is data" (parse-ffi-sexp "'foo") 'foo)

;;;; Malformed input must not poison later parses ;;;;
;; Steel's builtin `read` keeps global state across calls (leftover datums,
;; pending open parens); the hand-rolled parser must not.

(check-false! "multi-datum input rejected" (parse-ffi-sexp "1 2"))
(check-false! "trailing garbage rejected" (parse-ffi-sexp "(hash 'a 1) extra"))
(check-false! "unterminated form rejected" (parse-ffi-sexp "(hash 'value \"x\""))
(check-false! "empty input rejected" (parse-ffi-sexp ""))
(check-false! "whitespace-only input rejected" (parse-ffi-sexp "  \n\t "))
(check-equal! "parse still works after malformed inputs"
  (parse-ffi-sexp "(hash 'value \"ok\")")
  (hash 'value "ok"))

(summarize! "parse-ffi-sexp")
