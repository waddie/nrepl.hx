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
;;; lookup, describe, ls-sessions, and stats. Run from the repo root:
;;; steel tests/test-parse-ffi-sexp.scm

(require "steel-test/test.scm")
(require (only-in "../cogs/nrepl/string-utils.scm" parse-ffi-sexp))

;;;; Eval result hash (eval_result_to_steel_hashmap) ;;;;

(deftest eval-result
  (let ([r (parse-ffi-sexp
            "(hash 'value \"3\" 'output (list \"a\" \"b\") 'error #f 'ns \"user\" 'ex #f 'interrupted #f)")])
    (is (hash? r))
    (is (= "3" (hash-get r 'value)))
    (is (= (list "a" "b") (hash-get r 'output)))
    (is (= #f (hash-get r 'error)))
    (is (= "user" (hash-get r 'ns)))
    (is (= #f (hash-get r 'interrupted))))
  ;; Interrupted flag set
  (let ([r (parse-ffi-sexp "(hash 'value #f 'interrupted #t)")])
    (is (= #t (hash-get r 'interrupted)))))

;;;; need-input hash (nrepl_try_get_result NeedInput arm) ;;;;

(deftest need-input
  (let ([r (parse-ffi-sexp
            "(hash 'need-input #t 'request-id 7 'output (list \"Your name: \") 'error #f)")])
    (is (= #t (hash-get r 'need-input)))
    (is (= 7 (hash-get r 'request-id)))
    (is (= (list "Your name: ") (hash-get r 'output)))))

;;;; Completions (list of hashes with #: keys) ;;;;

(deftest completions
  (let ([r (parse-ffi-sexp
            "(list (hash '#:candidate \"map\" '#:ns \"clojure.core\" '#:type \"function\") (hash '#:candidate \"mapv\" '#:ns #f '#:type #f))")])
    (is (list? r))
    (is (= 2 (length r)))
    (is (= "map" (hash-get (car r) '#:candidate)))
    (is (= "clojure.core" (hash-get (car r) '#:ns)))
    (is (= #f (hash-get (cadr r) '#:ns)))))

;;;; Lookup (flat hash with #: keys) ;;;;

(deftest lookup
  (let ([r (parse-ffi-sexp "(hash '#:name \"map\" '#:doc \"docstring here\")")])
    (is (= "map" (hash-get r '#:name)))
    (is (= "docstring here" (hash-get r '#:doc)))))

;;;; Describe (nested hashes, string keys, empty sections) ;;;;

(deftest describe
  (let ([r (parse-ffi-sexp
            "(hash 'ops (list \"eval\" \"describe\") 'versions (hash \"nrepl\" (hash \"version-string\" \"1.3.0\")) 'aux (hash ))")])
    (is (= (list "eval" "describe") (hash-get r 'ops)))
    (is (= "1.3.0"
         (hash-get (hash-get (hash-get r 'versions) "nrepl") "version-string")))
    (is (= (hash) (hash-get r 'aux))))
  (let ([r (parse-ffi-sexp "(hash 'ops (list ) 'versions (hash ) 'aux (hash ))")])
    (is (= (list) (hash-get r 'ops)))))

;;;; ls-sessions (flat string list) ;;;;

(deftest ls-sessions
  (is (= (list "31f2c0a2-1" "31f2c0a2-2")
       (parse-ffi-sexp "(list \"31f2c0a2-1\" \"31f2c0a2-2\")"))))

;;;; Stats (numbers, nested list of hashes) ;;;;

(deftest stats
  (let ([r (parse-ffi-sexp
            "(hash 'total-connections 2 'total-sessions 3 'max-connections 100 'next-conn-id 5 'connections (list (hash 'id 1 'sessions (list \"abc\"))))")])
    (is (= 2 (hash-get r 'total-connections)))
    (is (= 100 (hash-get r 'max-connections)))
    (is (= (list "abc")
         (hash-get (car (hash-get r 'connections)) 'sessions)))))

;;;; Escaped strings round-trip ;;;;

(deftest escaped-strings
  (let ([r (parse-ffi-sexp "(hash 'value \"quote \\\" backslash \\\\ tab \\t newline \\n end\")")])
    (is (= "quote \" backslash \\ tab \t newline \n end"
         (hash-get r 'value)))))

;;;; Rejection: nothing outside the grammar may parse (or execute) ;;;;

(define *pwned* (box #f))
(define (pwn!)
  (set-box! *pwned* #t)
  "pwned")

(deftest rejection
  (is (not (parse-ffi-sexp "(system \"id\")")))
  (is (not (parse-ffi-sexp "(hash 'value (string-append \"a\" \"b\"))")))
  (is (not (parse-ffi-sexp "(pwn!)")))
  (is (not (parse-ffi-sexp "(hash 'value (pwn!))")))
  (is (= #f (unbox *pwned*)))
  (is (not (parse-ffi-sexp "not a sexp (")))
  (is (not (parse-ffi-sexp "some-symbol")))
  (is (not (parse-ffi-sexp "(hash 'value)")))
  (is (not (parse-ffi-sexp "()"))))

;;;; Quoted symbols pass through as data ;;;;

(deftest quoted-symbols
  (is (= 'foo (parse-ffi-sexp "'foo"))))

;;;; Malformed input must not poison later parses ;;;;
;; Steel's builtin `read` keeps global state across calls (leftover datums,
;; pending open parens); the hand-rolled parser must not.

(deftest malformed-input
  (is (not (parse-ffi-sexp "1 2")))
  (is (not (parse-ffi-sexp "(hash 'a 1) extra")))
  (is (not (parse-ffi-sexp "(hash 'value \"x\"")))
  (is (not (parse-ffi-sexp "")))
  (is (not (parse-ffi-sexp "  \n\t ")))
  (is (= (hash 'value "ok") (parse-ffi-sexp "(hash 'value \"ok\")"))))

(run-tests!)
