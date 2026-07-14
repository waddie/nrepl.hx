;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; completion-model.scm - Completion Candidate Model
;;;
;;; Pure transforms over parsed completion results (the output of
;;; parse-ffi-sexp on the FFI's completions string). No helix requires, so it
;;; loads under the bare steel CLI for headless tests.

(provide candidates->symbols+metadata)

;;@doc
;; Turn a parsed candidates list into (cons symbol-list metadata-hash).
;;
;; Each candidate is a hash with '#:candidate, '#:ns and '#:type keys (the
;; FFI emitter always writes all three; missing fields arrive as #f, e.g.
;; babashka sends no type). A bare string is accepted as a plain symbol with
;; no metadata. Anything else returns (cons '() (hash)).
;;
;; symbol-list preserves server order; metadata-hash maps candidate string ->
;; (hash '#:ns ns '#:type type).
(define (candidates->symbols+metadata candidates)
  (if (list? candidates)
    ;; Explicit cons/reverse loop: map with hash-constructing callbacks can
    ;; crash Helix under a full plugin module graph.
    (let loop ([remaining candidates]
               [symbols (list)]
               [metadata (hash)])
      (if (null? remaining)
        (cons (reverse symbols) metadata)
        (let ([item (car remaining)])
          (cond
            [(hash? item)
              (let ([candidate (hash-ref item '#:candidate)])
                (loop (cdr remaining)
                  (cons candidate symbols)
                  (hash-insert
                    metadata
                    candidate
                    (hash '#:ns (hash-ref item '#:ns) '#:type (hash-ref item '#:type)))))]
            [(string? item) ; plain-string fallback (old format)
              (loop (cdr remaining) (cons item symbols) metadata)]
            [else (loop (cdr remaining) symbols metadata)]))))
    (cons (list) (hash))))
