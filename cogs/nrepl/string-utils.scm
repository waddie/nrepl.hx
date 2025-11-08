;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; string-utils.scm - Shared String Utilities
;;;
;;; Common string processing functions used across the codebase.

(provide tokenize
         string-contains-ci?
         string-downcase
         eval-string)

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

;;;; Case-Insensitive String Operations ;;;;

;;@doc
;; Case-insensitive substring search.
;;
;; Returns #t if needle is found in haystack (case-insensitive), #f otherwise.
;; An empty needle always matches (returns #t).
;;
;; Parameters:
;;   haystack - The string to search in
;;   needle   - The substring to search for
;;
;; Returns:
;;   Boolean - #t if found, #f otherwise
;;
;; Example:
;;   (string-contains-ci? "Hello World" "WORLD")  => #t
;;   (string-contains-ci? "foo" "bar")            => #f
(define (string-contains-ci? haystack needle)
  (let ([hay-len (string-length haystack)]
        [needle-len (string-length needle)])
    (if (= needle-len 0)
        #t
        (let loop ([i 0])
          (cond
            [(> (+ i needle-len) hay-len) #f]
            [(string-ci=? (substring haystack i (+ i needle-len)) needle) #t]
            [else (loop (+ i 1))])))))

;;@doc
;; Convert string to lowercase (ASCII only).
;;
;; This is a simplified implementation for ASCII characters.
;; For full Unicode support, would need Rust FFI.
;;
;; Parameters:
;;   s - The string to convert
;;
;; Returns:
;;   String - Lowercase version of input
;;
;; Example:
;;   (string-downcase "Hello World")  => "hello world"
(define (string-downcase s)
  (list->string (map (lambda (c)
                       (if (and (char>=? c #\A) (char<=? c #\Z))
                           (integer->char (+ (char->integer c) 32))
                           c))
                     (string->list s))))

;;;; S-Expression Evaluation ;;;;

;;@doc
;; Safely evaluate string as S-expression.
;;
;; Attempts to read and evaluate a string as a Steel S-expression.
;; Returns #f if evaluation fails (parse error or evaluation error).
;;
;; Parameters:
;;   s - String containing S-expression
;;
;; Returns:
;;   The evaluated value, or #f on error
;;
;; Example:
;;   (eval-string "(+ 1 2)")  => 3
;;   (eval-string "invalid")  => #f
(define (eval-string s)
  (with-handler (lambda (e) #f) (eval (read (open-input-string s)))))
