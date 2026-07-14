;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; harness.scm - Minimal assertion harness for headless Steel tests
;;;
;;; Run tests from the repo root: steel < tests/<file>.scm
;;; (stdin resolves requires from the cwd, so module paths are repo-relative).
;;;
;;; The bare steel CLI exits 0 even on uncaught errors, so tests/run-all.sh
;;; detects success by the "SUITE-PASS" line summarize! prints; a crashed or
;;; failing suite never prints it.

(provide check-equal!
  check-true!
  check-false!
  summarize!)

(define *failures* (box 0))
(define *checks* (box 0))

;;@doc
;; Assert actual equals expected; on mismatch print a FAIL line with both.
(define (check-equal! label actual expected)
  (set-box! *checks* (+ 1 (unbox *checks*)))
  (if (equal? actual expected)
    #t
    (begin
      (set-box! *failures* (+ 1 (unbox *failures*)))
      (displayln (string-append "FAIL: " label))
      (displayln (string-append "  expected: " (to-string expected)))
      (displayln (string-append "  actual:   " (to-string actual)))
      #f)))

;;@doc
;; Assert value is truthy.
(define (check-true! label actual)
  (check-equal! label (if actual #t #f) #t))

;;@doc
;; Assert value is #f.
(define (check-false! label actual)
  (check-equal! label (if actual #t #f) #f))

;;@doc
;; Print the suite verdict. run-all.sh greps for the SUITE-PASS sentinel.
(define (summarize! name)
  (let ([f (unbox *failures*)]
        [c (unbox *checks*)])
    (if (= f 0)
      (displayln (string-append "SUITE-PASS " name " (" (to-string c) " checks)"))
      (displayln (string-append "SUITE-FAIL " name ": "
                  (to-string f)
                  " of "
                  (to-string c)
                  " checks failed")))))
