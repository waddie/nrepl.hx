;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; Process manager for nREPL jack-in
;; Spawns and manages nREPL server processes

(require "steel/result")
(require-builtin steel/process)

(provide spawned-process
         make-spawned-process
         spawned-process-process-handle
         spawned-process-command
         spawned-process-port
         spawned-process-workspace-root
         spawn-nrepl-server
         try-connect-to-port
         kill-server
         get-process-output)

;;; Spawned process struct

(struct spawned-process
        (process-handle ; Steel process handle from spawn-process
         command ; Command string that was executed
         port ; Port number server is using
         workspace-root) ; Where server was started
  #:transparent)

(define (make-spawned-process process-handle command port workspace-root)
  "Constructor for spawned-process"
  (spawned-process process-handle command port workspace-root))

;;; Process spawning

(define (spawn-nrepl-server cmd-string workspace-root port)
  "Spawn an nREPL server process with the given command.
   Returns spawned-process struct or #f on failure."
  (with-handler (lambda (err) #f) ; Return #f on error
                ;; CRITICAL: Redirect both stdout and stderr to prevent TUI corruption
                ;; Without this, nREPL server output goes directly to terminal
                (let* ([cmd-with-redirect (string-append cmd-string " >/dev/null 2>&1")]
                       [cmd (command "sh" (list "-c" cmd-with-redirect))]
                       [child-result (spawn-process cmd)]
                       [process-handle (Ok->value child-result)])
                  (make-spawned-process process-handle cmd-string port workspace-root))))

;;; Server readiness polling helper

(define (try-connect-to-port port)
  "Try to connect to a port to check if server is ready.
   Returns #t if connection succeeds, #f otherwise."
  (with-handler
   (lambda (err) #f) ; Connection failed
   ;; Try to connect using nc (netcat) with a short timeout
   ;; Redirect stderr to prevent TUI corruption
   (let* ([port-str (number->string port)]
          [cmd (command "sh"
                        (list "-c" (string-append "nc -z -w 1 localhost " port-str " 2>/dev/null")))]
          [child-result (spawn-process cmd)]
          [child (Ok->value child-result)]
          [exit-code-result (wait child)]
          [exit-code (Ok->value exit-code-result)])
     ;; nc returns 0 on successful connection
     (equal? exit-code 0))))

;;; Process management

(define (kill-server process-info)
  "Kill a spawned nREPL server process.
   Returns #t if killed successfully, #f otherwise."
  (with-handler (lambda (err) #f) ; Return #f on error
                ;; Kill by port number - more reliable than regex pattern matching
                ;; Use -sTCP:LISTEN to find only the server process (not connected clients like Helix)
                (let* ([port (spawned-process-port process-info)]
                       [port-pattern (string-append ":" (number->string port))]
                       [cmd (command "lsof" (list "-ti" port-pattern "-sTCP:LISTEN"))]
                       [_ (set-piped-stdout! cmd)]
                       [child-result (spawn-process cmd)]
                       [child (Ok->value child-result)]
                       [pids-str (Ok->value (wait->stdout child))]
                       [pids (filter (lambda (s) (not (equal? s ""))) (split-many pids-str "\n"))])
                  (if (null? pids)
                      #f ; No process found on that port
                      ;; Kill all PIDs found
                      (begin
                        (for-each (lambda (pid)
                                    (let* ([kill-cmd (command "kill" (list "-TERM" pid))]
                                           [kill-result (spawn-process kill-cmd)]
                                           [kill-child (Ok->value kill-result)])
                                      (wait kill-child)))
                                  pids)
                        #t)))))

(define (get-process-output process-handle)
  "Get stdout/stderr output from a spawned process.
   Returns string output or #f if unavailable."
  (with-handler (lambda (err) #f)
                ;; Try to read from stdout
                (let* ([stdout-handle (child-stdout process-handle)])
                  (if stdout-handle
                      (read-port-to-string stdout-handle)
                      #f))))
