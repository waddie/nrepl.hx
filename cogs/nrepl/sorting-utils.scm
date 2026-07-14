;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; sorting-utils.scm - Sorting Utilities
;;;
;;; General-purpose sorting functions for Steel Scheme.
;;; Based on merge-sort from steel-resources/steel/cogs/sorting/merge-sort.scm

(provide sort)

;;;; Merge Sort Implementation ;;;;

;;@doc
;; Merge two sorted lists using a comparator function.
;;
;; Stable: on ties (comparator says neither precedes the other), l1's element
;; is taken first, so l1 must hold the earlier elements of the original list.
;;
;; Parameters:
;;   l1 - First sorted list
;;   l2 - Second sorted list
;;   comparator - Function (a b) -> boolean, returns #t if a should come before b
;;
;; Returns:
;;   Merged sorted list
(define (merge-lists l1 l2 comparator)
  (if (null? l1)
    l2
    (if (null? l2)
      l1
      (if (comparator (car l2) (car l1))
        (cons (car l2) (merge-lists l1 (cdr l2) comparator))
        (cons (car l1) (merge-lists (cdr l1) l2 comparator))))))

;;@doc
;; First n elements of list.
(define (take-prefix l n)
  (if (or (= n 0) (null? l))
    '()
    (cons (car l) (take-prefix (cdr l) (- n 1)))))

;;@doc
;; List without its first n elements.
(define (drop-prefix l n)
  (if (or (= n 0) (null? l))
    l
    (drop-prefix (cdr l) (- n 1))))

;;@doc
;; Sort a list using merge sort algorithm.
;;
;; Stable sort - maintains relative order of equal elements.
;;
;; Parameters:
;;   l - List to sort
;;   comparator - Function (a b) -> boolean, returns #t if a should come before b
;;
;; Returns:
;;   Sorted list
;;
;; Examples:
;;   (sort '(3 1 4 1 5 9) <)           => (1 1 3 4 5 9)
;;   (sort '("foo" "bar" "baz") string<?)  => ("bar" "baz" "foo")
;;   (sort '((2 "b") (1 "a") (2 "c"))
;;         (lambda (a b) (< (car a) (car b))))  => ((1 "a") (2 "b") (2 "c"))
(define (sort l comparator)
  (if (or (null? l) (null? (cdr l)))
    l
    ;; Split into first and second half (not an odd/even interleave, which
    ;; would reorder equal elements and break stability).
    (let ([half (quotient (length l) 2)])
      (merge-lists (sort (take-prefix l half) comparator)
        (sort (drop-prefix l half) comparator)
        comparator))))
