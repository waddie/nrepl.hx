;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; Port management for nREPL jack-in
;; Functions for finding free ports and managing .nrepl-port files

(require "steel/result")
(require-builtin steel/process)

(provide find-free-port
         port-available?
         read-nrepl-port
         write-nrepl-port
         delete-nrepl-port)

;;; Port availability checking

(define (port-available? port)
  "Check if a port is available (not in use) by attempting to bind to it.
   Returns #t if port is free, #f if in use."
  (let* ([port-str (number->string port)]
         [cmd (command "lsof" (list "-i" (string-append ":" port-str)))]
         [_ (set-piped-stdout! cmd)]
         [child-result (spawn-process cmd)]
         [child (Ok->value child-result)]
         [output (Ok->value (wait->stdout child))])
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

(define (read-nrepl-port workspace-root)
  "Read port number from .nrepl-port file.
   Returns port number if file exists and is valid, #f otherwise."
  (let* ([port-file (nrepl-port-path workspace-root)])
    ;; Try to read the file, return #f if it doesn't exist or fails
    (with-handler (lambda (err) #f) ; Return #f on any error
                  (let* ([content (read-port-to-string (open-input-file port-file))]
                         [trimmed (trim content)])
                    ;; Try to parse as number
                    (if (equal? trimmed "")
                        #f
                        (let ([port (string->number trimmed)])
                          (if (and port (> port 0) (<= port 65535)) port #f)))))))

(define (write-nrepl-port workspace-root port)
  "Write port number to .nrepl-port file.
   Returns #t on success, #f on failure."
  (let* ([port-file (nrepl-port-path workspace-root)]
         [port-str (number->string port)]
         ;; Use shell command to write file (printf to avoid trailing newline)
         [cmd-str (string-append "printf '%s' " port-str " > " port-file)]
         [cmd (command "sh" (list "-c" cmd-str))]
         [child-result (spawn-process cmd)]
         [child (Ok->value child-result)])
    (wait child)
    #t))

(define (delete-nrepl-port workspace-root)
  "Delete .nrepl-port file if it exists.
   Returns #t if deleted or doesn't exist, #f on error."
  (let* ([port-file (nrepl-port-path workspace-root)])
    ;; Use rm -f to avoid error messages on stderr that corrupt TUI
    (with-handler (lambda (err) #t) ; Return #t even on error (file might not exist)
                  (let* ([cmd (command "rm" (list "-f" port-file))]
                         [child-result (spawn-process cmd)]
                         [child (Ok->value child-result)])
                    (wait child)
                    #t))))
