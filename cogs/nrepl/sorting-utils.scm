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
          (if (comparator (car l1) (car l2))
              (cons (car l1) (merge-lists (cdr l1) l2 comparator))
              (cons (car l2) (merge-lists (cdr l2) l1 comparator))))))

;;@doc
;; Extract elements at even positions from list.
;;
;; Parameters:
;;   l - Input list
;;
;; Returns:
;;   List of elements at even positions (0-indexed: 2nd, 4th, 6th, etc.)
(define (even-elements l)
  (if (null? l)
      '()
      (if (null? (cdr l))
          '()
          (cons (car (cdr l)) (even-elements (cdr (cdr l)))))))

;;@doc
;; Extract elements at odd positions from list.
;;
;; Parameters:
;;   l - Input list
;;
;; Returns:
;;   List of elements at odd positions (0-indexed: 1st, 3rd, 5th, etc.)
(define (odd-elements l)
  (if (null? l)
      '()
      (if (null? (cdr l))
          (list (car l))
          (cons (car l) (odd-elements (cdr (cdr l)))))))

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
  (if (null? l)
      l
      (if (null? (cdr l))
          l
          (merge-lists (sort (odd-elements l) comparator)
                       (sort (even-elements l) comparator)
                       comparator))))
