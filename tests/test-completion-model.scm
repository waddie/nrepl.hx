;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; test-completion-model.scm - candidates->symbols+metadata
;;;
;;; Run from the repo root: steel < tests/test-completion-model.scm

(require "tests/harness.scm")
(require "cogs/nrepl/completion-model.scm")
(require (only-in "cogs/nrepl/string-utils.scm" parse-ffi-sexp))

;; cider-shaped candidates: all fields present.
(let* ([parsed (parse-ffi-sexp
                "(list (hash '#:candidate \"map\" '#:ns \"clojure.core\" '#:type \"function\") (hash '#:candidate \"mapv\" '#:ns \"clojure.core\" '#:type \"function\"))")]
       [result (candidates->symbols+metadata parsed)])
  (check-equal! "cider shape: symbols in server order" (car result) '("map" "mapv"))
  (check-equal! "cider shape: ns metadata"
    (hash-ref (hash-ref (cdr result) "map") '#:ns)
    "clojure.core")
  (check-equal! "cider shape: type metadata"
    (hash-ref (hash-ref (cdr result) "map") '#:type)
    "function"))

;; babashka-shaped candidates: ns present, type #f.
(let* ([parsed (parse-ffi-sexp
                "(list (hash '#:candidate \"map\" '#:ns \"clojure.core\" '#:type #f))")]
       [result (candidates->symbols+metadata parsed)])
  (check-equal! "babashka shape: symbol extracted" (car result) '("map"))
  (check-equal! "babashka shape: ns present"
    (hash-ref (hash-ref (cdr result) "map") '#:ns)
    "clojure.core")
  (check-false! "babashka shape: type is #f"
    (hash-ref (hash-ref (cdr result) "map") '#:type)))

;; Empty result (babashka on an empty prefix).
(let ([result (candidates->symbols+metadata (parse-ffi-sexp "(list )"))])
  (check-equal! "empty list: no symbols" (car result) '())
  (check-equal! "empty list: no metadata" (hash-length (cdr result)) 0))

;; Plain-string fallback (old format): symbol kept, no metadata entry.
(let ([result (candidates->symbols+metadata (list "map" "mapv"))])
  (check-equal! "string fallback: symbols kept" (car result) '("map" "mapv"))
  (check-equal! "string fallback: no metadata" (hash-length (cdr result)) 0))

;; Mixed shapes: hashes and strings interleaved.
(let* ([parsed (parse-ffi-sexp
                "(list \"plain\" (hash '#:candidate \"rich\" '#:ns \"user\" '#:type \"var\"))")]
       [result (candidates->symbols+metadata parsed)])
  (check-equal! "mixed shapes: order preserved" (car result) '("plain" "rich"))
  (check-equal! "mixed shapes: only hash has metadata" (hash-length (cdr result)) 1))

;; Non-list input (parse failure upstream returns #f).
(let ([result (candidates->symbols+metadata #f)])
  (check-equal! "non-list input: no symbols" (car result) '())
  (check-equal! "non-list input: no metadata" (hash-length (cdr result)) 0))

;; Unexpected element types are dropped.
(let ([result (candidates->symbols+metadata (list 42 "ok"))])
  (check-equal! "unexpected elements dropped" (car result) '("ok")))

(summarize! "completion-model")
