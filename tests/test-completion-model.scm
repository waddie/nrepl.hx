;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; test-completion-model.scm - candidates->symbols+metadata
;;;
;;; Run from the repo root: steel tests/test-completion-model.scm

(require "steel-test/test.scm")
(require "../cogs/nrepl/completion-model.scm")
(require (only-in "../cogs/nrepl/string-utils.scm" parse-ffi-sexp))

;; cider-shaped candidates: all fields present.
(deftest cider-shape
  (let* ([parsed (parse-ffi-sexp
                  "(list (hash '#:candidate \"map\" '#:ns \"clojure.core\" '#:type \"function\") (hash '#:candidate \"mapv\" '#:ns \"clojure.core\" '#:type \"function\"))")]
         [result (candidates->symbols+metadata parsed)])
    (is (= '("map" "mapv") (car result)))
    (is (= "clojure.core" (hash-ref (hash-ref (cdr result) "map") '#:ns)))
    (is (= "function" (hash-ref (hash-ref (cdr result) "map") '#:type)))))

;; babashka-shaped candidates: ns present, type #f.
(deftest babashka-shape
  (let* ([parsed (parse-ffi-sexp
                  "(list (hash '#:candidate \"map\" '#:ns \"clojure.core\" '#:type #f))")]
         [result (candidates->symbols+metadata parsed)])
    (is (= '("map") (car result)))
    (is (= "clojure.core" (hash-ref (hash-ref (cdr result) "map") '#:ns)))
    (is (not (hash-ref (hash-ref (cdr result) "map") '#:type)))))

;; Empty result (babashka on an empty prefix).
(deftest empty-result
  (let ([result (candidates->symbols+metadata (parse-ffi-sexp "(list )"))])
    (is (= '() (car result)))
    (is (= 0 (hash-length (cdr result))))))

;; Plain-string fallback (old format): symbol kept, no metadata entry.
(deftest string-fallback
  (let ([result (candidates->symbols+metadata (list "map" "mapv"))])
    (is (= '("map" "mapv") (car result)))
    (is (= 0 (hash-length (cdr result))))))

;; Mixed shapes: hashes and strings interleaved.
(deftest mixed-shapes
  (let* ([parsed (parse-ffi-sexp
                  "(list \"plain\" (hash '#:candidate \"rich\" '#:ns \"user\" '#:type \"var\"))")]
         [result (candidates->symbols+metadata parsed)])
    (is (= '("plain" "rich") (car result)))
    (is (= 1 (hash-length (cdr result))))))

;; Non-list input (parse failure upstream returns #f).
(deftest non-list-input
  (let ([result (candidates->symbols+metadata #f)])
    (is (= '() (car result)))
    (is (= 0 (hash-length (cdr result))))))

;; Unexpected element types are dropped.
(deftest unexpected-elements-dropped
  (let ([result (candidates->symbols+metadata (list 42 "ok"))])
    (is (= '("ok") (car result)))))

(deftest poll-delay-backoff
  (is (= 10 (poll-delay-for 0)))
  (is (= 10 (poll-delay-for 199)))
  (is (= 25 (poll-delay-for 200)))
  (is (= 25 (poll-delay-for 1999)))
  (is (= 50 (poll-delay-for 2000)))
  (is (= 50 (poll-delay-for 29000))))

(run-tests!)
