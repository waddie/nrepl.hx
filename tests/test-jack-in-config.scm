;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; test-jack-in-config.scm - jack-in configuration system tests
;;;
;;; Run from the repo root: steel tests/test-jack-in-config.scm

(require "steel-test/test.scm")
(require "../cogs/nrepl/jack-in-config.scm")

(deftest default-versions
  (is (= "1.7.0" (jack-in-version 'nrepl)))
  (is (= "0.62.1" (jack-in-version 'cider-nrepl)))
  (is (= "0.7.0" (jack-in-version 'piggieback))))

(deftest version-appears-in-clojure-command
  (let ([cmd (build-clojure-command 7888 #f)])
    (is (string-contains? cmd "nrepl/nrepl {:mvn/version \"1.7.0\"}"))
    (is (string-contains? cmd "cider/cider-nrepl {:mvn/version \"0.62.1\"}"))))

(deftest version-override
  (nrepl-set-jack-in-version 'cider-nrepl "0.99.0")
  (is (string-contains? (build-clojure-command 7888 #f) "0.99.0"))
  (nrepl-set-jack-in-version 'cider-nrepl "0.62.1"))

(deftest middleware-vector-default
  (is (= "[cider.nrepl/cider-middleware]" (jack-in-middleware-vector))))

(deftest lein-injects-cider-nrepl
  (let ([cmd (build-leiningen-command 7890)])
    (is (string-contains? cmd "update-in :dependencies conj '[nrepl/nrepl \"1.7.0\"]' --"))
    (is (string-contains? cmd "update-in :plugins conj '[cider/cider-nrepl \"0.62.1\"]' --"))
    (is (string-contains? cmd "trampoline repl :headless :port 7890"))))

(deftest shell-quoting
  (is (= "'plain'" (shell-single-quote "plain")))
  (is (= "'it'\\''s'" (shell-single-quote "it's"))))

(deftest env-prefix
  (is (= "" (jack-in-env-prefix)))
  (nrepl-set-jack-in-env '(("FOO" . "bar") ("BAZ" . "a b")))
  (is (= "export FOO='bar'; export BAZ='a b'; " (jack-in-env-prefix)))
  (nrepl-set-jack-in-env '()))

(deftest project-config-loads-and-applies
  (is (load-project-config "tests/fixtures/config-project"))
  (is (= "custom-bb 7888" (build-babashka-command 7888)))
  (is (= "export CFG='yes'; " (jack-in-env-prefix)))
  (nrepl-set-jack-in-env '()))

(deftest after-jack-in-code-config
  (is (null? (after-jack-in-code)))
  (nrepl-set-after-jack-in-code "(require 'dev)")
  (is (= (list "(require 'dev)") (after-jack-in-code)))
  (nrepl-set-after-jack-in-code (list "(a)" "(b)"))
  (is (= (list "(a)" "(b)") (after-jack-in-code)))
  (nrepl-set-after-jack-in-code '()))

(deftest nbb-command
  (is (= "npx nbb nrepl-server :port 7888" (build-nbb-command 7888))))

(deftest basilisp-command
  (is (= "basilisp nrepl-server --port 7888" (build-basilisp-command 7888)))
  (is (= "basilisp nrepl-server --port 7888"
       (get-jack-in-command 'python-poetry 7888 #f))))

(deftest lein-with-profiles
  (let ([cmd (build-leiningen-command 7890 (list "dev" "test"))])
    (is (string-contains? cmd "with-profile +dev,+test trampoline repl :headless"))
    (is (string-contains? cmd "update-in :plugins")))
  ;; no profiles: unchanged shape
  (is (string-contains? (build-leiningen-command 7890)
       "trampoline repl :headless :port 7890")))

(deftest shadow-command
  (is (= "npx shadow-cljs -d cider/cider-nrepl:0.62.1 watch app test"
       (build-shadow-command (list "app" "test"))))
  (is (= "npx shadow-cljs -d cider/cider-nrepl:0.62.1 server"
       (build-shadow-command '()))))

(deftest extra-middleware-appended
  (nrepl-add-jack-in-middleware "my.mw/wrap")
  (is (= "[cider.nrepl/cider-middleware my.mw/wrap]" (jack-in-middleware-vector)))
  (is (string-contains? (build-clojure-command 7888 #f) "my.mw/wrap")))

(deftest piggieback-injection
  (let ([before (build-clojure-command 7888 #f)])
    (is (not (string-contains? before "piggieback"))))
  (nrepl-enable-piggieback)
  (let ([cmd (build-clojure-command 7888 #f)])
    (is (string-contains? cmd "cider/piggieback {:mvn/version \"0.7.0\"}"))
    (is (string-contains? cmd "cider.piggieback/wrap-cljs-repl"))))

(deftest custom-lein-template-still-wins
  (nrepl-configure-jack-in 'leiningen (lambda (port) "custom-lein"))
  (is (= "custom-lein" (build-leiningen-command 7890 (list "dev"))))
  (nrepl-configure-jack-in 'shadow-cljs (lambda (builds) "custom-shadow"))
  (is (= "custom-shadow" (build-shadow-command (list "app")))))

(deftest project-config-idempotent-and-isolated
  ;; Double load must not duplicate state.
  (is (load-project-config "tests/fixtures/config-project"))
  (is (load-project-config "tests/fixtures/config-project"))
  (is (= "export CFG='yes'; " (jack-in-env-prefix)))
  ;; A workspace with no config restores the baseline: no leak from the
  ;; previous project (env cleared, custom-bb override gone, the leftover
  ;; lein/shadow overrides from the template test gone).
  (is (not (load-project-config "tests/fixtures/lein-project")))
  (is (= "" (jack-in-env-prefix)))
  (is (= "bb nrepl-server 7888" (build-babashka-command 7888)))
  (is (string-contains? (build-leiningen-command 7890) "trampoline repl :headless")))

(deftest project-config-middleware-not-duplicated
  (is (load-project-config "tests/fixtures/config-mw-project"))
  (is (load-project-config "tests/fixtures/config-mw-project"))
  (is (= "[cider.nrepl/cider-middleware my.project/mw]" (jack-in-middleware-vector)))
  ;; Restore for any later test.
  (load-project-config "tests/fixtures/lein-project"))

(deftest config-errors-are-surfaced
  (load-project-config "tests/fixtures/config-bad-project")
  (is (not (null? (config-load-errors))))
  (is (load-project-config "tests/fixtures/config-project"))
  (is (null? (config-load-errors))))

(run-tests!)
