;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; Port management for nREPL jack-in
;; Functions for finding free ports and managing .nrepl-port files

(require-builtin steel/filesystem)
(require (only-in "run-command/run-command.scm" run-argv))

(provide find-free-port
  port-available?
  read-port-file
  read-nrepl-port
  write-nrepl-port
  delete-nrepl-port)

;;; Port availability checking

(define (port-available? port)
  "Check if a port is available (not in use) by attempting to bind to it.
   Returns #t if port is free, #f if in use."
  (let* ([port-str (number->string port)]
         [result (run-argv "lsof" (list "-i" (string-append ":" port-str)))]
         [output (hash-ref result 'stdout)])
    ;; lsof returns empty string if port is free, output if in use
    (equal? output "")))

(define (find-free-port start-port end-port)
  "Find the first available port in the range [start-port, end-port].
   Returns port number if found, #f if no ports available."
  (let loop ([port start-port])
    (cond
      [(> port end-port) #f] ; No free ports found
      [(port-available? port) port] ; Found free port
      [else (loop (+ port 1))]))) ; Try next port

;;; .nrepl-port file management

(define (nrepl-port-path workspace-root)
  "Get the path to .nrepl-port file in workspace"
  (string-append workspace-root "/.nrepl-port"))

(define (read-port-file path)
  "Read a port number from a file containing just the port. #f if missing/invalid."
  (with-handler (lambda (err) #f)
    (let* ([content (read-port-to-string (open-input-file path))]
           [trimmed (trim content)])
      (if (equal? trimmed "")
        #f
        (let ([port (string->number trimmed)])
          (if (and port (> port 0) (<= port 65535)) port #f))))))

(define (read-nrepl-port workspace-root)
  "Read port number from .nrepl-port file. #f if missing/invalid."
  (read-port-file (nrepl-port-path workspace-root)))

(define (write-nrepl-port workspace-root port)
  "Write port number to .nrepl-port file.
   Returns #t on success, #f on failure."
  (with-handler (lambda (err) #f)
    (let* ([port-file (nrepl-port-path workspace-root)]
           [port-str (number->string port)]
           ;; Write with no trailing newline, matching the previous `printf '%s'`.
           [out (open-output-file port-file #:exists 'truncate)])
      (display port-str out)
      (close-output-port out)
      #t)))

(define (delete-nrepl-port workspace-root)
  "Delete .nrepl-port file if it exists.
   Returns #t if deleted or doesn't exist, #f on error."
  (let* ([port-file (nrepl-port-path workspace-root)])
    ;; #t even if absent (nothing to delete is success), like the old `rm -f`.
    (with-handler (lambda (err) #t)
      (when (path-exists? port-file)
        (delete-file! port-file))
      #t)))
