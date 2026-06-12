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
         spawned-process-log-path
         spawn-nrepl-server
         try-connect-to-port
         server-exit-code
         kill-server
         get-process-output)

;;; Spawned process struct

(struct spawned-process
        (process-handle ; Steel process handle from spawn-process
         command ; Command string that was executed
         port ; Port number server is using
         workspace-root ; Where server was started
         log-path) ; File the server's stdout/stderr is redirected to
  #:transparent)

(define (make-spawned-process process-handle command port workspace-root log-path)
  "Constructor for spawned-process"
  (spawned-process process-handle command port workspace-root log-path))

;;; Temp-file paths for capturing a spawned server's output and exit status.
;;; Keyed by port so a jack-in re-uses (and overwrites) the same files rather
;;; than accumulating temp files. macOS-native, like the rest of jack-in.

(define (server-log-path port)
  (string-append "/tmp/nrepl-hx-jackin-" (number->string port) ".log"))

(define (server-exit-path port)
  (string-append "/tmp/nrepl-hx-jackin-" (number->string port) ".exit"))

;; Run a shell command, discarding output, waiting for it to finish.
(define (run-quietly shell-cmd)
  (with-handler (lambda (err) #f)
                (let* ([cmd (command "sh" (list "-c" shell-cmd))]
                       [child (Ok->value (spawn-process cmd))])
                  (wait child)
                  #t)))

;; Read a file's contents via `cat`. Returns the contents, or #f if the file is
;; missing or empty. A blocking read on a *file* (unlike a pipe to a live
;; process) cannot deadlock, which is why the server is redirected to a file
;; rather than piped.
(define (read-file-contents path)
  (with-handler (lambda (err) #f)
                (let* ([cmd (command "sh"
                                     (list "-c" (string-append "cat \"" path "\" 2>/dev/null")))]
                       [_ (set-piped-stdout! cmd)]
                       [child (Ok->value (spawn-process cmd))]
                       [out (Ok->value (wait->stdout child))])
                  (if (equal? out "") #f out))))

;;; Process spawning

(define (spawn-nrepl-server cmd-string workspace-root port)
  "Spawn an nREPL server process with the given command.
   Returns spawned-process struct or #f on failure."
  (with-handler (lambda (err) #f) ; Return #f on error
                (let* ([log-path (server-log-path port)]
                       [exit-path (server-exit-path port)]
                       ;; Clear any log/sentinel left by a previous jack-in on
                       ;; this port, so a stale exit file can't be mistaken for
                       ;; this run's failure.
                       [_ (run-quietly (string-append "rm -f \"" log-path "\" \"" exit-path "\""))]
                       ;; Redirect the server's stdout+stderr to a log FILE (not
                       ;; the terminal — that would corrupt the TUI; not a pipe —
                       ;; reading a live process's pipe would block). Then drop
                       ;; an exit-code sentinel when the command returns, so the
                       ;; poll loop can fail fast when the command dies straight
                       ;; away (e.g. not found on PATH) instead of waiting out
                       ;; the full 30s timeout.
                       [wrapped (string-append "{ " cmd-string " ; } > \"" log-path
                                               "\" 2>&1; echo $? > \"" exit-path "\"")]
                       [cmd (command "sh" (list "-c" wrapped))]
                       [child-result (spawn-process cmd)]
                       [process-handle (Ok->value child-result)])
                  (make-spawned-process process-handle cmd-string port workspace-root log-path))))

;;; Server readiness polling helper

(define (server-exit-code process-info)
  "If the spawned server command has already exited, return its exit code as a
   trimmed string; otherwise #f (still running). A non-#f result means the
   server died before binding its port — jack-in should give up immediately."
  (let ([raw (read-file-contents (server-exit-path (spawned-process-port process-info)))])
    (if raw (trim raw) #f)))

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
                ;; Drop the jack-in log/sentinel temp files for this port.
                (run-quietly (string-append "rm -f \"" (spawned-process-log-path process-info)
                                            "\" \"" (server-exit-path (spawned-process-port process-info)) "\""))
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

(define (get-process-output process-info)
  "Read whatever the spawned server wrote to its log file (stdout + stderr).
   Returns the captured text, or #f if nothing was captured."
  (read-file-contents (spawned-process-log-path process-info)))
