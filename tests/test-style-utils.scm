;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; test-style-utils.scm - picker line styling
;;;
;;; Run from the repo root: steel tests/test-style-utils.scm

(require "steel-test/test.scm")
(require "../cogs/nrepl/style-utils.scm")

(deftest style-utils
  (testing "style-lines pairs each line with the style"
    (is (= '() (style-lines '() 's)))
    (is (= (list (cons "a" 's) (cons "b" 's))
         (style-lines (list "a" "b") 's)))))

(run-tests!)
