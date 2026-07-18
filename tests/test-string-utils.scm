;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; test-string-utils.scm - tokenize and string helpers
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
  (testing "drop-prefix"
    (is (= "x" (drop-prefix "Error: x" "Error: ")))
    (is (= "abc" (drop-prefix "abc" "zzz")))
    (is (= "" (drop-prefix "ab" "ab")))
    (is (= "ab" (drop-prefix "ab" "abc"))))
  (testing "string-prefix?"
    (is (string-prefix? "abc" "ab"))
    (is (string-prefix? "abc" ""))
    (is (not (string-prefix? "abc" "bc")))
    (is (not (string-prefix? "a" "ab"))))
  (testing "string-suffix?"
    (is (string-suffix? "abc" "bc"))
    (is (string-suffix? "abc" ""))
    (is (not (string-suffix? "abc" "ab")))
    (is (not (string-suffix? "a" "ab"))))
  (testing "find-char-index"
    (is (= 1 (find-char-index "abc" #\b 0)))
    (is (equal? #f (find-char-index "abc" #\z 0)))
    (is (= 3 (find-char-index "a/b/c" #\/ 2)))
    (is (equal? #f (find-char-index "abc" #\a 1))))
  (testing "find-last-char"
    (is (= 3 (find-last-char "a/b/c" #\/)))
    (is (equal? #f (find-last-char "abc" #\/)))))

(run-tests!)
