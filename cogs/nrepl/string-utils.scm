;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; string-utils.scm - Shared String Utilities
;;;
;;; Common string processing functions used across the codebase.

(provide tokenize)

;;;; Tokenization ;;;;

;;@doc
;; Split string on any character in delimiters string.
;;
;; This function tokenizes a string by splitting on any of the specified delimiter
;; characters. It returns a list of non-empty tokens.
;;
;; Parameters:
;;   str        - The string to tokenize
;;   delimiters - String containing delimiter characters (e.g., " \t\n{}" for whitespace and braces)
;;
;; Returns:
;;   List of non-empty token strings
;;
;; Example:
;;   (tokenize "{:foo :bar}" " {}")  => (":" "foo" ":" "bar")
(define (tokenize str delimiters)
  (define (is-delimiter? pos)
    (let loop ([i 0])
      (if (>= i (string-length delimiters))
          #f
          (if (equal? (substring str pos (+ pos 1)) (substring delimiters i (+ i 1)))
              #t
              (loop (+ i 1))))))

  (define (collect-token start end)
    (if (= start end)
        #f ; Empty token
        (substring str start end)))

  (let loop ([pos 0]
             [token-start 0]
             [tokens '()])
    (if (>= pos (string-length str))
        ;; End of string - collect final token if any
        (let ([final-token (collect-token token-start pos)])
          (reverse (if final-token
                       (cons final-token tokens)
                       tokens)))
        ;; Check if current char is delimiter
        (if (is-delimiter? pos)
            ;; Found delimiter - collect token and skip delimiter
            (let ([token (collect-token token-start pos)])
              (loop (+ pos 1)
                    (+ pos 1)
                    (if token
                        (cons token tokens)
                        tokens)))
            ;; Not a delimiter - continue current token
            (loop (+ pos 1) token-start tokens)))))
