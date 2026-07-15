;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; test-adapters.scm - pure formatting behavior of the language adapters
;;;
;;; Run from the repo root: steel tests/test-adapters.scm
;;; Needs repl-ui.hx installed in ~/.steel/cogs (adapter-utils re-exports it).

(require "steel-test/test.scm")
(require "../cogs/nrepl/adapter-interface.scm")
(require "../cogs/nrepl/generic.scm")
(require "../cogs/nrepl/clojure.scm")
(require "../cogs/nrepl/janet.scm")

(define generic (make-generic-adapter))
(define clojure (make-clojure-adapter))
(define janet (make-janet-adapter))

(deftest generic-adapter
  (is (= "Generic nREPL" (adapter-language-name generic)))
  (is (= ";;" (adapter-comment-prefix generic)))
  (is (= "user=> (+ 1 2)\n" (adapter-format-prompt generic "user" "(+ 1 2)" 3)))
  (is (= "=> (+ 1 2)\n" (adapter-format-prompt generic #f "(+ 1 2)" 3)))
  (is (= "boom" (adapter-prettify-error generic "boom\ndetails\nmore")))
  (is (not (adapter-jack-in-cmd generic #f 12345))))

(deftest clojure-adapter
  (is (= ";;" (adapter-comment-prefix clojure)))
  (is (= "my.ns=> (inc 1)\n" (adapter-format-prompt clojure "my.ns" "(inc 1)" #f)))
  (is (= "Arity error - Wrong number of arguments"
       (adapter-prettify-error clojure
         "Execution error (ArityException) at test.core/eval123 (REPL:1).")))
  (is (= "Type error - Cannot cast value to expected type"
       (adapter-prettify-error clojure
         "Execution error (ClassCastException) at test.core (REPL:1)."))))

(deftest janet-adapter
  (is (= "#" (adapter-comment-prefix janet)))
  (is (= '(".janet" ".jdn") (adapter-file-extensions janet)))
  (is (= "repl:3:> (+ 1 2)\n" (adapter-format-prompt janet #f "(+ 1 2)" 3)))
  (is (= "repl:> (+ 1 2)\n" (adapter-format-prompt janet #f "(+ 1 2)" #f)))
  (is (= "unknown symbol foobar"
       (adapter-prettify-error janet "error: unknown symbol foobar\n  in thunk")))
  (is (= "Type error - no matching method for arguments"
       (adapter-prettify-error janet "error: could not find method :+ for 1")))
  (is (= "Syntax error - malformed expression"
       (adapter-prettify-error janet
         "error: unexpected end of source, ( opened at line 1"))))

(deftest format-result
  ;; A successful eval with output: prompt, output, then value.
  (is (= "user=> (+ 1 2)\nhi\n3\n\n"
       (adapter-format-result generic "(+ 1 2)"
         (hash 'value "3" 'output (list "hi\n") 'error #f 'ns "user")))))

(run-tests!)
