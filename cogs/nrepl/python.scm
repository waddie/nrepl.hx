;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; python.scm - Python Language Adapter
;;;
;;; Language adapter for Python nREPL servers.
;;; Handles Python-specific error formatting and traceback parsing.

(require "cogs/nrepl/adapter-interface.scm")
(require "cogs/nrepl/adapter-utils.scm")

(provide make-python-adapter)

;;;; Helper Functions ;;;;

;;@doc
;; Simplify Python exception names to user-friendly terms
(define (simplify-exception-name ex-name)
  (cond
    [(string-contains? ex-name "NameError") "Name error"]
    [(string-contains? ex-name "TypeError") "Type error"]
    [(string-contains? ex-name "ValueError") "Value error"]
    [(string-contains? ex-name "AttributeError") "Attribute error"]
    [(string-contains? ex-name "KeyError") "Key error"]
    [(string-contains? ex-name "IndexError") "Index error"]
    [(string-contains? ex-name "SyntaxError") "Syntax error"]
    [(string-contains? ex-name "IndentationError") "Indentation error"]
    [(string-contains? ex-name "ImportError") "Import error"]
    [(string-contains? ex-name "ModuleNotFoundError") "Module not found"]
    [(string-contains? ex-name "ZeroDivisionError") "Division by zero"]
    [(string-contains? ex-name "RuntimeError") "Runtime error"]
    [else "Error"]))

;;@doc
;; Extract location info from Python traceback
(define (extract-location err-str)
  (cond
    ;; Look for "File \"...\", line X"
    [(string-contains? err-str "line ")
     (let* ([parts (split-many err-str "line ")]
            [rest (if (> (length parts) 1)
                      (cadr parts)
                      "")]
            [num-str (car (split-many rest ","))]
            [line-num (string->number (trim num-str))])
       (if line-num
           (string-append "line " (number->string line-num))
           ""))]
    [else ""]))

;;@doc
;; Extract the error description after the exception type
(define (extract-error-description err-str)
  (cond
    ;; Python format: "ExceptionType: description"
    [(string-contains? err-str ":")
     (let ([parts (split-many err-str ":")])
       (if (> (length parts) 1)
           (trim (string-join (cdr parts) ":"))
           err-str))]
    [else (take-first-line err-str)]))

;;@doc
;; Transform Python error messages into concise format
;; Examples:
;;   "NameError: name 'foo' is not defined"
;;     -> "Name error - name 'foo' is not defined"
;;   "TypeError: unsupported operand type(s)"
;;     -> "Type error - unsupported operand type(s)"
(define (prettify-error-message err-str)
  (cond
    ;; Pattern 1: Standard Python exception format "ExceptionType: message"
    [(or (string-contains? err-str "Error:") (string-contains? err-str "Exception:"))
     (let* ([first-line (take-first-line err-str)]
            [parts (split-many first-line ":")]
            [exception-type (if (null? parts)
                                "Error"
                                (trim (car parts)))]
            [simplified (simplify-exception-name exception-type)]
            [description (extract-error-description first-line)]
            [location (extract-location err-str)]
            [location-part (if (string=? location "")
                               ""
                               (string-append " at " location))])
       (string-append simplified location-part " - " description))]

    ;; Pattern 2: Connection errors
    [(string-contains? err-str "Connection")
     (cond
       [(string-contains? err-str "refused") "Connection refused - Is nREPL server running?"]
       [(string-contains? err-str "timeout") "Connection timeout - Check address and firewall"]
       [(string-contains? err-str "reset") "Connection lost - Server closed the connection"]
       [else (take-first-line err-str)])]

    ;; Pattern 3: Timeout
    [(string-contains? err-str "timed out")
     "Evaluation timed out - Expression took too long to execute"]

    ;; Fallback: just take first line
    [else (take-first-line err-str)]))

;;;; Adapter Implementation ;;;;

;;@doc
;; Python-specific error prettification
(define (prettify-error-python err-str)
  (prettify-error-message err-str))

;;@doc
;; Python prompt format (using >>> like standard Python REPL)
(define (format-prompt-python namespace code)
  (string-append ">>> " code "\n"))

;;@doc
;; Format evaluation result with Python styling
(define (format-result-python code result)
  (format-result-common code result format-prompt-python prettify-error-python "#"))

;;;; Jack-In Support ;;;;

;;@doc
;; Jack-in not currently supported for Python
;;
;; Returns #f to indicate jack-in is not available
(define (jack-in-cmd-python project-info port)
  "Python jack-in not yet implemented"
  #f)

;;;; Adapter Constructor ;;;;

;;@doc
;; Create a Python language adapter instance
;;
;; This adapter handles Python exceptions and tracebacks, using the
;; standard >>> prompt format familiar to Python developers.
(define (make-python-adapter)
  (make-adapter prettify-error-python
                format-prompt-python
                format-result-python
                "Python"
                '(".py" ".pyw")
                "#"
                jack-in-cmd-python))
