;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; clojure.scm - Clojure Language Adapter
;;;
;;; Language adapter for Clojure, Babashka, and other Clojure variants.
;;; Handles Clojure-specific error formatting, Java exception parsing,
;;; and namespace-aware prompts.

(require "cogs/nrepl/adapter-interface.scm")

(provide make-clojure-adapter)

;;;; Helper Functions ;;;;

;;@doc
;; Extract the first meaningful line from an error message
(define (take-first-line err-str)
  (let ([lines (split-many err-str "\n")])
    (if (null? lines)
        err-str
        (trim (car lines)))))

;;@doc
;; Check if a string contains only whitespace
(define (whitespace-only? str)
  (string=? (trim str) ""))

;;@doc
;; Simplify Java exception names to user-friendly terms
(define (simplify-exception-name ex-name)
  (cond
    [(string-contains? ex-name "ArityException") "Arity error"]
    [(string-contains? ex-name "ClassCast") "Type error"]
    [(string-contains? ex-name "NullPointer") "Null reference"]
    [(string-contains? ex-name "IllegalArgument") "Invalid argument"]
    [(string-contains? ex-name "RuntimeException") "Runtime error"]
    [(string-contains? ex-name "CompilerException") "Compilation error"]
    [else "Error"]))

;;@doc
;; Extract location info from Clojure error format (file:line:col)
(define (extract-location err-str)
  ;; Look for patterns like "user.clj:15:23" or "at (file.clj:10)"
  ;; Return "line X:Y" or empty string if not found
  (cond
    [(string-contains? err-str ".clj:")
     (let* ([parts (split-many err-str ":")]
            ;; Filter to get numeric parts (line and column numbers)
            [numeric-parts
             (filter (lambda (s) (let ([num (string->number (trim s))]) (and num (> num 0)))) parts)])
       (if (>= (length numeric-parts) 2)
           (string-append "line " (car numeric-parts) ":" (cadr numeric-parts))
           (if (>= (length numeric-parts) 1)
               (string-append "line " (car numeric-parts))
               "")))]
    [else ""]))

;;@doc
;; Extract meaningful description from error message
(define (extract-error-description err-str)
  (cond
    ;; "Unable to resolve symbol: foo"
    [(string-contains? err-str "Unable to resolve")
     (let ([parts (split-many err-str ":")])
       (if (> (length parts) 1)
           (trim (string-join (cdr parts) ":"))
           err-str))]
    ;; "Wrong number of args"
    [(string-contains? err-str "Wrong number") (take-first-line err-str)]
    ;; Default: first line
    [else (take-first-line err-str)]))

;;@doc
;; Transform verbose error messages into concise, single-line format
;; Examples:
;;   "Execution error (ArityException) at test.core/eval123 (REPL:1)."
;;     -> "Arity error - Wrong number of arguments"
;;   "Execution error (ClassCastException) at test.core (REPL:1)."
;;     -> "Type error - Cannot cast value to expected type"
(define (prettify-error-message err-str)
  (cond
    ;; Pattern 1: Clojure "Execution error (ExceptionType)" format
    [(string-contains? err-str "error (")
     (let* ([simplified-type
             (cond
               [(string-contains? err-str "ArityException") "Arity error - Wrong number of arguments"]
               [(string-contains? err-str "ClassCastException")
                "Type error - Cannot cast value to expected type"]
               [(string-contains? err-str "NullPointerException")
                "Null reference - Attempted to use null value"]
               [(string-contains? err-str "IllegalArgumentException")
                "Invalid argument - Value not accepted"]
               [(string-contains? err-str "RuntimeException") "Runtime error"]
               [(string-contains? err-str "CompilerException") "Compilation error"]
               [else (take-first-line err-str)])])
       simplified-type)]

    ;; Pattern 2: Exception with colon separator (Java-style)
    [(string-contains? err-str "Exception:")
     (let* ([parts (split-many err-str ":")]
            [exception-type (simplify-exception-name (car parts))]
            [location (extract-location err-str)]
            [description (extract-error-description err-str)]
            [location-part (if (string=? location "")
                               ""
                               (string-append " at " location))])
       (string-append exception-type location-part " - " description))]

    ;; Pattern 3: nREPL transport/connection errors
    [(string-contains? err-str "Connection")
     (cond
       [(string-contains? err-str "refused") "Connection refused - Is nREPL server running?"]
       [(string-contains? err-str "timeout") "Connection timeout - Check address and firewall"]
       [(string-contains? err-str "reset") "Connection lost - Server closed the connection"]
       [else (take-first-line err-str)])]

    ;; Pattern 4: Evaluation timeout
    [(string-contains? err-str "timed out")
     "Evaluation timed out - Expression took too long to execute"]

    ;; Fallback: just take first line and trim
    [else (take-first-line err-str)]))

;;@doc
;; Format an error string as commented lines
(define (format-error-as-comment err-str)
  (let* ([lines (split-many err-str "\n")]
         [commented-lines (map (lambda (line) (string-append ";; " line)) lines)])
    (string-join commented-lines "\n")))

;;;; Adapter Implementation ;;;;

;;@doc
;; Clojure-specific error prettification
(define (prettify-error-clojure err-str)
  (prettify-error-message err-str))

;;@doc
;; Clojure prompt format with namespace support
(define (format-prompt-clojure namespace code)
  (let ([prompt (if (and namespace (not (eq? namespace #f)))
                    (string-append namespace "=> ")
                    "=> ")])
    (string-append prompt code "\n")))

;;@doc
;; Format evaluation result with Clojure styling
(define (format-result-clojure code result)
  (let ([value (hash-get result 'value)]
        [output (hash-get result 'output)]
        [error (hash-get result 'error)]
        [ns (hash-get result 'ns)])

    ;; Build the output string
    (let ([parts '()]
          [prompt (if (and ns (not (eq? ns #f)))
                      (string-append ns "=> ")
                      "=> ")])
      ;; Add the code that was evaluated with namespace prompt
      (set! parts (cons (string-append prompt code "\n") parts))

      ;; Add any stdout output (skip whitespace-only)
      (when (and output (not (null? output)))
        (for-each (lambda (out)
                    (when (not (whitespace-only? out))
                      (set! parts (cons out parts))))
                  output))

      ;; Add any stderr/error output (skip whitespace-only)
      (when (and error (not (eq? error #f)) (not (whitespace-only? error)))
        (set! parts
              (cons (string-append "✗ "
                                   (prettify-error-message error)
                                   "\n"
                                   (format-error-as-comment error)
                                   "\n")
                    parts)))

      ;; Add the result value (skip whitespace-only)
      (when (and value (not (eq? value #f)) (not (whitespace-only? value)))
        (set! parts (cons (string-append value "\n") parts)))

      ;; Add trailing newline to separate responses
      (set! parts (cons "\n" parts))

      ;; Combine all parts in reverse order (since we cons'd them)
      (apply string-append (reverse parts)))))

;;;; Adapter Constructor ;;;;

;;@doc
;; Create a Clojure language adapter instance
;;
;; This adapter handles Clojure/Java exceptions, provides namespace-aware
;; prompts, and formats errors in Clojure's standard format.
(define (make-clojure-adapter)
  (make-adapter
   prettify-error-clojure
   format-prompt-clojure
   format-result-clojure
   "Clojure"
   '(".clj" ".cljc" ".edn")
   ";;"))
