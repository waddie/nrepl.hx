;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; test-project-detection.scm - project detection from a fixture deps.edn
;;;
;;; Run from the repo root: steel tests/test-project-detection.scm
;;; (fixture paths are relative to the repo root)

(require "steel-test/test.scm")
(require "../cogs/nrepl/project-detection.scm")

(define fixture "tests/fixtures/clj-project/deps.edn")
(define info (detect-project-from-file fixture))
(define aliases (project-info-aliases info))
(define dev-alias (car aliases))
(define test-alias (cadr aliases))

(deftest detect-from-fixture
  (is (project-info? info))
  (is (= 'clojure-cli (project-info-project-type info)))
  (is (= "tests/fixtures/clj-project" (project-info-project-root info)))
  (is (= fixture (project-info-project-file info)))
  (is (not (project-info-has-nrepl-port? info))))

(deftest alias-extraction
  (is (list? aliases))
  (is (= 2 (length aliases)))
  (is (= "dev" (alias-info-name dev-alias)))
  (is (alias-info-has-main-opts? dev-alias))
  (is (= "test" (alias-info-name test-alias)))
  (is (not (alias-info-has-main-opts? test-alias))))

(deftest missing-and-unrecognized
  (is (not (detect-project-from-file "tests/fixtures/clj-project/nonexistent.edn")))
  (is (not (detect-project-from-file #f)))
  (is (not (detect-project-from-file
            "tests/fixtures/clj-project/deps.edn/../deps.edn.bak"))))

(run-tests!)
