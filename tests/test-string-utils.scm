;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; test-string-utils.scm - tokenize / string-contains-ci? / string-downcase
;;;
;;; Run from the repo root: steel tests/test-string-utils.scm

(require "steel-test/test.scm")
(require "../cogs/nrepl/string-utils.scm")

(deftest string-utils
  (testing "tokenize"
    (is (= (list "foo" "bar" "baz") (tokenize "foo bar baz" " ")))
    (is (= (list "foo" "bar") (tokenize "{:foo :bar}" " {}:")))
    (is (= (list "a" "b") (tokenize "  a   b  " " ")))
    (is (= (list) (tokenize "" " ")))
    (is (= (list "abc") (tokenize "abc" ","))))
  (testing "string-contains-ci?"
    (is (string-contains-ci? "Hello World" "WORLD"))
    (is (string-contains-ci? "hello" "ell"))
    (is (not (string-contains-ci? "foo" "bar")))
    (is (string-contains-ci? "foo" ""))
    (is (not (string-contains-ci? "a" "ab"))))
  (testing "string-downcase"
    (is (= "hello world" (string-downcase "Hello World")))
    (is (= "abc" (string-downcase "abc")))
    (is (= "a1:b2" (string-downcase "A1:B2")))
    (is (= "" (string-downcase "")))))

(run-tests!)
