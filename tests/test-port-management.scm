;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; test-port-management.scm - port-management.scm tests
;;;
;;; Run from the repo root: steel tests/test-port-management.scm

(require-builtin steel/filesystem)
(require "steel-test/test.scm")
(require "../cogs/nrepl/port-management.scm")

(deftest read-port-file-generic
  (let ([path "tests/fixtures/tmp-port-file"])
    (let ([out (open-output-file path #:exists 'truncate)])
      (display "51234" out)
      (close-output-port out))
    (is (= 51234 (read-port-file path)))
    (delete-file! path))
  (is (not (read-port-file "tests/fixtures/does-not-exist"))))

(run-tests!)
