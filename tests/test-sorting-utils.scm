;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; test-sorting-utils.scm - merge sort
;;;
;;; Run from the repo root: steel < tests/test-sorting-utils.scm

(require "tests/harness.scm")
(require "cogs/nrepl/sorting-utils.scm")

(check-equal! "sort numbers" (sort '(3 1 4 1 5 9) <) '(1 1 3 4 5 9))
(check-equal! "sort strings" (sort '("foo" "bar" "baz") string<?) '("bar" "baz" "foo"))
(check-equal! "sort empty" (sort '() <) '())
(check-equal! "sort singleton" (sort '(1) <) '(1))
(check-equal! "sort already sorted" (sort '(1 2 3) <) '(1 2 3))
(check-equal! "sort reverse input" (sort '(3 2 1) <) '(1 2 3))

;; Stability: equal keys keep their relative order.
(check-equal! "sort is stable"
  (sort '((2 "b") (1 "a") (2 "c"))
    (lambda (a b) (< (car a) (car b))))
  '((1 "a") (2 "b") (2 "c")))

(summarize! "sorting-utils")
