;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; test-project-detection.scm - project detection from a fixture deps.edn
;;;
;;; Run from the repo root: steel < tests/test-project-detection.scm
;;; (paths are relative to the repo root)

(require "tests/harness.scm")
(require "cogs/nrepl/project-detection.scm")

;;;; detect-project-from-file on the fixture ;;;;

(define fixture "tests/fixtures/clj-project/deps.edn")
(define info (detect-project-from-file fixture))

(check-true! "fixture detected" (project-info? info))
(check-equal! "project type" (project-info-project-type info) 'clojure-cli)
(check-equal! "project root" (project-info-project-root info) "tests/fixtures/clj-project")
(check-equal! "project file" (project-info-project-file info) fixture)
(check-false! "no .nrepl-port in fixture" (project-info-has-nrepl-port? info))

;;;; Alias extraction ;;;;

(define aliases (project-info-aliases info))

(check-true! "aliases found" (list? aliases))
(check-equal! "two aliases" (length aliases) 2)

(define dev-alias (car aliases))
(define test-alias (cadr aliases))

(check-equal! "dev alias name" (alias-info-name dev-alias) "dev")
(check-true! "dev alias has :main-opts" (alias-info-has-main-opts? dev-alias))
(check-equal! "test alias name" (alias-info-name test-alias) "test")
(check-false! "test alias has no :main-opts" (alias-info-has-main-opts? test-alias))

;;;; Missing / unrecognized files ;;;;

(check-false! "missing file returns #f"
  (detect-project-from-file "tests/fixtures/clj-project/nonexistent.edn"))
(check-false! "#f filepath returns #f" (detect-project-from-file #f))
(check-false! "unrecognized file returns #f"
  (detect-project-from-file "tests/fixtures/clj-project/deps.edn/../deps.edn.bak"))

(summarize! "project-detection")
