;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; test-sorting-utils.scm - merge sort
;;;
;;; Run from the repo root: steel tests/test-sorting-utils.scm

(require "steel-test/test.scm")
(require "../cogs/nrepl/sorting-utils.scm")

(deftest sorting
  (is (= '(1 1 3 4 5 9) (sort '(3 1 4 1 5 9) <)))
  (is (= '("bar" "baz" "foo") (sort '("foo" "bar" "baz") string<?)))
  (is (= '() (sort '() <)))
  (is (= '(1) (sort '(1) <)))
  (is (= '(1 2 3) (sort '(1 2 3) <)))
  (is (= '(1 2 3) (sort '(3 2 1) <)))
  ;; Stability: equal keys keep their relative order.
  (is (= '((1 "a") (2 "b") (2 "c"))
       (sort '((2 "b") (1 "a") (2 "c"))
         (lambda (a b) (< (car a) (car b)))))))

(run-tests!)
