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
(require "cogs/nrepl/adapter-utils.scm")
(require "cogs/nrepl/jack-in-config.scm")
(require "cogs/nrepl/project-detection.scm")

(provide make-clojure-adapter)

;;;; Helper Functions ;;;;

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
  (format-result-common code result format-prompt-clojure prettify-error-clojure ";;"))

;;;; Jack-In Support ;;;;

;;@doc
;; Generate jack-in command for Clojure/Babashka projects
;;
;; Parameters:
;;   project-info - project-info struct with project type and alias-info list
;;   port         - Port number to start server on
;;
;; Returns:
;;   Command string or #f if not supported
(define (jack-in-cmd-clojure project-info port)
  "Generate jack-in command for Clojure project"
  (let ([project-type (project-info-project-type project-info)]
        [alias-infos (project-info-aliases project-info)])
    (get-jack-in-command project-type port alias-infos)))

;;;; Adapter Constructor ;;;;

;;@doc
;; Create a Clojure language adapter instance
;;
;; This adapter handles Clojure/Java exceptions, provides namespace-aware
;; prompts, and formats errors in Clojure's standard format.
(define (make-clojure-adapter)
  (make-adapter prettify-error-clojure
                format-prompt-clojure
                format-result-clojure
                "Clojure"
                '(".clj" ".cljc" ".edn")
                ";;"
                jack-in-cmd-clojure))
