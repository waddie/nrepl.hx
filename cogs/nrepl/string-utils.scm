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
  drop-prefix
  string-prefix?
  string-suffix?
  find-char-index
  find-last-char
  parse-ffi-sexp)

;;;; String Predicates and Searching ;;;;

;;@doc
;; Drop a fixed prefix from the front of a string when present, else return it
;; unchanged.
(define (drop-prefix str prefix)
  (let ([plen (string-length prefix)])
    (if (and (>= (string-length str) plen)
         (string=? (substring str 0 plen) prefix))
      (substring str plen (string-length str))
      str)))

;;@doc
;; Does str start with prefix?
(define (string-prefix? str prefix)
  (let ([plen (string-length prefix)])
    (and (>= (string-length str) plen)
      (string=? (substring str 0 plen) prefix))))

;;@doc
;; Does str end with suffix?
(define (string-suffix? str suffix)
  (let ([slen (string-length str)]
        [xlen (string-length suffix)])
    (and (>= slen xlen)
      (string=? (substring str (- slen xlen) slen) suffix))))

;;@doc
;; Index of the first occurrence of char ch in s at or after start, or #f.
(define (find-char-index s ch start)
  (let ([len (string-length s)])
    (let loop ([i start])
      (cond
        [(>= i len) #f]
        [(char=? (string-ref s i) ch) i]
        [else (loop (+ i 1))]))))

;;@doc
;; Index of the last occurrence of char ch in s, or #f.
(define (find-last-char s ch)
  (let loop ([i (- (string-length s) 1)])
    (cond
      [(< i 0) #f]
      [(char=? (string-ref s i) ch) i]
      [else (loop (- i 1))])))

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

;;;; FFI Result Parsing ;;;;

;; A hand-rolled recursive-descent parser rather than the builtin `read`:
;; Steel's `read` (verified 0.8.2) keeps global state across calls - extra
;; datums from one port are served to later `read` calls, and an unterminated
;; "(" silently swallows the next port's content - so one malformed input
;; would poison every parse after it. This parser is pure: it walks the
;; string by index and shares nothing between calls.
;;
;; Each ffi-parse-* helper takes the string, a start index, and the string
;; length, and returns (cons parsed-value next-index). Anything outside the
;; FFI grammar raises; parse-ffi-sexp catches and returns #f.

;; Advance past whitespace; returns the next non-whitespace index (or len).
(define (ffi-skip-ws s i len)
  (let loop ([i i])
    (if (and (< i len)
         (let ([c (string-ref s i)])
           (or (char=? c #\space)
             (char=? c #\tab)
             (char=? c #\newline)
             (char=? c #\return))))
      (loop (+ i 1))
      i)))

;; Index just past the current atom (stops at whitespace or a delimiter).
(define (ffi-atom-end s i len)
  (let loop ([i i])
    (if (>= i len)
      i
      (let ([c (string-ref s i)])
        (if (or (char=? c #\space)
             (char=? c #\tab)
             (char=? c #\newline)
             (char=? c #\return)
             (char=? c #\()
             (char=? c #\))
             (char=? c #\")
             (char=? c #\'))
          i
          (loop (+ i 1)))))))

;; Parse a string literal body (i points just past the opening quote),
;; decoding the escapes the Rust side emits: \" \\ \n \r \t.
(define (ffi-parse-string s i len)
  (let loop ([i i] [acc '()])
    (if (>= i len)
      (error "parse-ffi-sexp: unterminated string")
      (let ([c (string-ref s i)])
        (cond
          [(char=? c #\") (cons (list->string (reverse acc)) (+ i 1))]
          [(char=? c #\\)
            (if (>= (+ i 1) len)
              (error "parse-ffi-sexp: dangling escape")
              (let ([e (string-ref s (+ i 1))])
                (cond
                  [(char=? e #\") (loop (+ i 2) (cons #\" acc))]
                  [(char=? e #\\) (loop (+ i 2) (cons #\\ acc))]
                  [(char=? e #\n) (loop (+ i 2) (cons #\newline acc))]
                  [(char=? e #\r) (loop (+ i 2) (cons #\return acc))]
                  [(char=? e #\t) (loop (+ i 2) (cons #\tab acc))]
                  [else (error "parse-ffi-sexp: unknown escape")])))]
          [else (loop (+ i 1) (cons c acc))])))))

;; Parse the elements of a (list ...) form up to the closing paren.
(define (ffi-parse-list-args s i len)
  (let loop ([i i] [acc '()])
    (let ([i (ffi-skip-ws s i len)])
      (cond
        [(>= i len) (error "parse-ffi-sexp: unterminated form")]
        [(char=? (string-ref s i) #\)) (cons (reverse acc) (+ i 1))]
        [else
          (let ([r (ffi-parse-value s i len)])
            (loop (cdr r) (cons (car r) acc)))]))))

;; Parse the arguments of a (hash ...) form into a hash.
(define (ffi-parse-hash-args s i len)
  (let* ([r (ffi-parse-list-args s i len)]
         [args (car r)])
    (if (even? (length args))
      (cons (apply hash args) (cdr r))
      (error "parse-ffi-sexp: odd hash arguments"))))

;; Parse a parenthesised form (i points just past the open paren). Only
;; (hash ...) and (list ...) exist in the FFI grammar.
(define (ffi-parse-form s i len)
  (let* ([i (ffi-skip-ws s i len)]
         [end (ffi-atom-end s i len)]
         [head (substring s i end)])
    (cond
      [(string=? head "hash") (ffi-parse-hash-args s end len)]
      [(string=? head "list") (ffi-parse-list-args s end len)]
      [else (error "parse-ffi-sexp: form outside FFI grammar")])))

;; Parse one value: string, number, boolean, quoted symbol/keyword, or a
;; (hash ...) / (list ...) form.
(define (ffi-parse-value s i len)
  (let ([i (ffi-skip-ws s i len)])
    (if (>= i len)
      (error "parse-ffi-sexp: unexpected end of input")
      (let ([c (string-ref s i)])
        (cond
          [(char=? c #\") (ffi-parse-string s (+ i 1) len)]
          [(char=? c #\()
            (ffi-parse-form s (+ i 1) len)]
          [(char=? c #\')
            ;; Quoted symbol or keyword, e.g. 'value or '#:ns.
            (let* ([start (+ i 1)]
                   [end (ffi-atom-end s start len)])
              (if (= end start)
                (error "parse-ffi-sexp: empty quoted symbol")
                (cons (string->symbol (substring s start end)) end)))]
          [(char=? c #\)) (error "parse-ffi-sexp: unexpected close paren")]
          [else
            (let* ([end (ffi-atom-end s i len)]
                   [text (substring s i end)])
              (cond
                [(or (string=? text "#t") (string=? text "#true")) (cons #t end)]
                [(or (string=? text "#f") (string=? text "#false")) (cons #f end)]
                [else
                  (let ([n (string->number text)])
                    (if n
                      (cons n end)
                      (error "parse-ffi-sexp: bare symbol outside FFI grammar")))]))])))))

;;@doc
;; Parse an FFI result string into data without eval.
;;
;; The Rust FFI layer returns results as S-expression strings limited to a
;; fixed grammar: (hash k v ...), (list e ...), quoted symbols/keywords, and
;; string/number/boolean literals. This parses the string directly into the
;; value. Nothing is evaluated, so result strings can never execute code in
;; the editor, whatever a server sends.
;;
;; Input must be exactly one value; empty input and trailing content fail.
;;
;; Parameters:
;;   s - FFI result string, e.g. "(hash 'value \"3\" 'output (list))"
;;
;; Returns:
;;   The parsed value, or #f on a parse error or any form outside the grammar
(define (parse-ffi-sexp s)
  (with-handler (lambda (e) #f)
    (let* ([len (string-length s)]
           [r (ffi-parse-value s 0 len)]
           [rest (ffi-skip-ws s (cdr r) len)])
      (if (< rest len)
        #f
        (car r)))))
