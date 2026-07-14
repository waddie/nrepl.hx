;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; test-string-utils.scm - tokenize / string-contains-ci? / string-downcase
;;;
;;; Run from the repo root: steel < tests/test-string-utils.scm

(require "tests/harness.scm")
(require "cogs/nrepl/string-utils.scm")

;;;; tokenize ;;;;

(check-equal! "tokenize on whitespace"
  (tokenize "foo bar baz" " ")
  (list "foo" "bar" "baz"))

(check-equal! "tokenize with multiple delimiters"
  (tokenize "{:foo :bar}" " {}:")
  (list "foo" "bar"))

(check-equal! "tokenize drops empty tokens"
  (tokenize "  a   b  " " ")
  (list "a" "b"))

(check-equal! "tokenize empty string" (tokenize "" " ") (list))

(check-equal! "tokenize no delimiters present"
  (tokenize "abc" ",")
  (list "abc"))

;;;; string-contains-ci? ;;;;

(check-true! "ci match differing case" (string-contains-ci? "Hello World" "WORLD"))
(check-true! "ci match same case" (string-contains-ci? "hello" "ell"))
(check-false! "ci no match" (string-contains-ci? "foo" "bar"))
(check-true! "ci empty needle" (string-contains-ci? "foo" ""))
(check-false! "ci needle longer than haystack" (string-contains-ci? "a" "ab"))

;;;; string-downcase ;;;;

(check-equal! "downcase mixed" (string-downcase "Hello World") "hello world")
(check-equal! "downcase already lower" (string-downcase "abc") "abc")
(check-equal! "downcase non-letters untouched" (string-downcase "A1:B2") "a1:b2")
(check-equal! "downcase empty" (string-downcase "") "")

(summarize! "string-utils")
