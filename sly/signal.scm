;;; Sly
;;; Copyright (C) 2013, 2014 David Thompson <dthompson2@worcester.edu>
;;;
;;; This program is free software: you can redistribute it and/or
;;; modify it under the terms of the GNU General Public License as
;;; published by the Free Software Foundation, either version 3 of the
;;; License, or (at your option) any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with this program.  If not, see
;;; <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Simple functional reactive programming API.
;;
;;; Code:

(define-module (sly signal)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (srfi srfi-26)
  #:use-module (sly agenda)
  #:use-module (sly coroutine)
  #:export (signal?
            make-signal
            define-signal
            signal-let signal-let*
            hook->signal
            signal-ref
            signal-ref-maybe
            signal-set!
            signal-merge
            signal-zip
            signal-map signal-sample-on
            signal-negate
            signal-fold
            signal-filter
            signal-drop
            signal-drop-repeats
            signal-switch
            signal-constant
            signal-count
            signal-tap
            signal-timestamp signal-time
            signal-sample
            signal-every signal-timer signal-since
            signal-delay
            signal-throttle
            signal-generator))

;;;
;;; Signals
;;;

;; Signals are time-varying values. For example, a signal could
;; represent the mouse position at the current point in time. The
;; signals API provides an abstraction over regular event-based
;; programming. State mutation is hidden away and a functional,
;; declarative interface is exposed.
(define-record-type <signal>
  (%%make-signal value proc inputs outputs)
  %signal?
  (value %signal-ref %%signal-set!)
  (proc signal-proc)
  (inputs signal-inputs)
  (outputs signal-outputs))

(define-record-type <signal-box>
  (make-signal-box signal)
  signal-box?
  (signal signal-unbox signal-box-set!))

;; The user always sees the boxes, so let's hide the underlying
;; details.
(set-record-type-printer!
 <signal-box>
 (lambda (box port)
   (let ((signal (signal-unbox box)))
     (format port "#<signal value: ~a inputs: ~a>"
             (%signal-ref signal) (signal-inputs signal)))))

;; Alternate spelling of signal-box? for the public API.
(define signal? signal-box?)

(define (%make-signal init proc inputs)
  "Create a new signal with initial value INIT."
  (let ((signal (%%make-signal init proc inputs (make-weak-key-hash-table))))
    (for-each (cut signal-connect! signal <>) inputs)
    signal))

(define (make-signal value)
  "Wrap VALUE in a signal."
  (make-signal-box (%make-signal value #f '())))

(define (make-boxed-signal init proc inputs)
  "Return a signal box containing a signal with value INIT, updating
procedure PROC, and a list of INPUTS."
  (make-signal-box (%make-signal init proc inputs)))

(define (signal-connect! signal-out signal-box-in)
  "Attach SIGNAL-OUT to SIGNAL-BOX-IN.  When the signal within
SIGNAL-BOX-IN changes, the value will be propagated to SIGNAL-OUT."
  (hashq-set! (signal-outputs (signal-unbox signal-box-in)) signal-out #f))

(define (signal-ref signal)
  "Return the value stored within SIGNAL."
  (%signal-ref (signal-unbox signal)))

(define (signal-ref-maybe object)
  "Return the value stored within OBJECT if OBJECT is a signal.
Otherwise, return OBJECT."
  (if (signal-box? object)
      (signal-ref object)
      object))

(define (signal-propagate! signal)
  "Notify all output signals about the current value of SIGNAL."
  (hash-for-each (lambda (output unused)
                   ((signal-proc output) output (%signal-ref signal)))
                 (signal-outputs signal)))

(define (%signal-set! signal value)
  "Change the current value of SIGNAL to VALUE and propagate VALUE to
all output signals."
  (%%signal-set! signal value)
  (signal-propagate! signal)
  *unspecified*)

(define (signal-set! signal value)
  "Change the contents of SIGNAL to VALUE.  This procedure should
almost never be used, except to bootstrap a root node of a signal
graph."
  (%signal-set! (signal-unbox signal) value))

(define (splice-signals! to from)
  "Replace the contents of the signal TO with the contents of the
signal FROM and transfer all output signals."
  (let ((outputs (signal-outputs (signal-unbox to))))
    (hash-for-each (lambda (signal unused)
                     (signal-connect! signal from))
                   outputs)
    (signal-box-set! to (signal-unbox from))))

(define (make-signal-maybe value)
  "Coerce VALUE into a signal.  Return VALUE unmodified if it is
already a signal."
  (if (signal? value)
      value
      (make-signal value)))

(define-syntax define-signal
  (lambda (x)
    "Create a top-level signal variable.  If the named variable
already exists and has a signal value then its outputs will be spliced
into the new signal.  If the given value is not a signal then it will
be coerced into one."
    (syntax-case x ()
      ((_ name (signal ...))
       (defined? (syntax->datum #'name))
       #'(let ((s (make-signal-maybe (signal ...))))
           (if (signal? name)
               (begin
                 (splice-signals! name s)
                 (signal-propagate! (signal-unbox name)))
               (set! name s))))
      ((_ name value)
       (defined? (syntax->datum #'name))
       #'(let ((s (make-signal-maybe value)))
           (if (signal? name)
               (begin
                 (splice-signals! name s)
                 (signal-propagate! (signal-unbox name)))
               (set! name s))))
      ((_ name (signal ...))
       #'(define name (make-signal-maybe (signal ...))))
      ((_ name value)
       #'(define name (make-signal-maybe value))))))

;; emacs: (put 'signal-let 'scheme-indent-function 1)

(define-syntax-rule (signal-let ((var signal) ...) body ...)
  "Similar to 'let', but produces a signal whose value is dependent
upon all signals in the bindings list."
  (signal-map (lambda (var ...) body ...) signal ...))

;; emacs: (put 'signal-let* 'scheme-indent-function 1)

(define-syntax-rule (signal-let* ((var signal) ...) body ...)
  "Similar to 'signal-let', but the signal variable bindings are
performed sequentially."
  (let* ((var signal) ...)
    (signal-map (lambda (var ...) body ...) var ...)))

;;;
;;; Signal Combinators
;;;

(define (hook->signal hook init proc)
  "Return a new signal whose initial value is INIT and has future
values calculated by applying PROC to the arguments sent when HOOK is
run."
  (let ((signal (make-signal init)))
    (add-hook! hook
               (lambda args
                 (signal-set! signal (apply proc args))))
    signal))

(define (signal-merge signal1 signal2 . rest)
  "Create a new signal whose value is the that of the most recently
changed signal in SIGNAL1, SIGNAL2, etc.  The initial value is that of
SIGNAL1."
  (let ((inputs (cons* signal1 signal2 rest)))
    (make-boxed-signal (signal-ref (car inputs))
                       (lambda (self value)
                         (%signal-set! self value))
                       inputs)))

(define (signal-zip . signals)
  "Create a new signal whose value is a list of the values stored
SIGNALS."
  (define (current-value)
    (map signal-ref signals))
  (make-boxed-signal (current-value)
                     (lambda (self value)
                       (%signal-set! self (current-value)))
                     signals))

(define (signal-map proc signal . rest)
  "Create a new signal that applies PROC to the values stored in one
or more SIGNALs."
  (let ((inputs (cons signal rest)))
    (define (current-value)
      (apply proc (map signal-ref inputs)))
    (make-boxed-signal (current-value)
                       (lambda (self value)
                         (%signal-set! self (current-value)))
                       inputs)))

(define (signal-sample-on value-signal sample-signal)
  "Create a new signal that takes on the value of VALUE-SIGNAL
whenever SAMPLE-SIGNAL receives a new value."
  (signal-map (lambda _ (signal-ref value-signal)) sample-signal))

(define (signal-negate signal)
  "Create a new signal whose value is the 'not' of the value of
SIGNAL."
  (signal-map not signal))

(define (signal-fold proc init signal . rest)
  "Create a new signal that applies PROC to the values stored in
SIGNAL. PROC is applied with the current value of SIGNAL and the
previously computed value, or INIT for the first call."
  (let ((inputs (cons signal rest)))
    (make-boxed-signal init
                       (let ((previous init))
                         (lambda (self value)
                           (let ((x (apply proc
                                           (append (map signal-ref inputs)
                                                   (list previous)))))
                             (set! previous x)
                             (%signal-set! self x))))
                       inputs)))

(define (signal-filter predicate default signal)
  "Create a new signal that keeps an incoming value from SIGNAL when
it satisfies the procedure PREDICATE.  The value of the signal is
DEFAULT in the case that the predicate is never satisfied."
  (make-boxed-signal (if (predicate (signal-ref signal))
                         (signal-ref signal)
                         default)
                     (lambda (self value)
                       (when (predicate value)
                         (%signal-set! self value)))
                     (list signal)))

(define (signal-drop predicate default signal)
  "Create a new signal that does not keep an incoming value from
SIGNAL when it satisfies the procedure PREDICATE.  The value of the
signal is DEFAULT when the predicate is never satisfied."
  (signal-filter (lambda (x) (not (predicate x))) default signal))

(define* (signal-drop-repeats signal #:optional (equal? equal?))
  "Create a new signal that drops the value received from SIGNAL when
it is equivalent to the current value.  By default, equal? is used for
testing equivalence."
  (signal-drop (let ((prev (signal-ref signal)))
                 (lambda (current)
                   (if (equal? prev current)
                       #t
                       (begin
                         (set! prev current)
                         #f))))
               (signal-ref signal)
               signal))

(define (signal-switch predicate on off)
  "Create a new signal whose value is that of the signal ON when the
signal PRED is true, or the value of the signal OFF otherwise."
  (define (current-value)
    (if (signal-ref predicate)
        (signal-ref on)
        (signal-ref off)))
  (make-boxed-signal (current-value)
                     (lambda (self value)
                       (%signal-set! self (current-value)))
                     (list predicate)))

(define (signal-constant constant signal)
  "Create a new signal whose value is always CONSTANT no matter the
value of SIGNAL."
  (signal-map (lambda (value) constant) signal))

(define* (signal-count signal #:optional (start 0) (step 1))
  "Create a new signal that increments a counter by STEP every time a
new value from SIGNAL is received, with an initial value of START.  By
default, START is 0 and STEP is 1."
  (signal-fold + start (signal-constant step signal)))

(define (signal-tap proc signal)
  "Create a new signal that applies PROC when a new value is received
from SIGNAL.  The value of the new signal will always be the value of
SIGNAL.  This signal is a convenient way to sneak a procedure that has
a side-effect into a signal chain."
  (signal-map (lambda (x) (proc x) x) signal))

(define (signal-timestamp signal)
  "Create a new signal whose value is a pair, the car of which is the
time that the value of SIGNAL was received and whose cdr is the value
of SIGNAL."
  (signal-map (cut cons (agenda-time) <>) signal))

(define (signal-time signal)
  "Create a new signal whose value is the time that the latest value
of SIGNAL was received."
  (signal-map (lambda _ (agenda-time)) signal))

(define (signal-sample step signal)
  "Create a new signal that takes on the value of SIGNAL every STEP
ticks."
  ;; To prevent memory leaks, the new signal is stored within a weak
  ;; value hash table and never bound to a variable within the main
  ;; body of the procedure.  When this signal is GC'd, the sampling
  ;; will stop.
  (let ((container (make-weak-value-hash-table 1)))
    (define (get)
      (hash-ref container 'signal))

    (define (sample!)
      (and=> (get)
             (lambda (sampler)
               (signal-set! sampler (signal-ref signal))
               #t)))

    (hash-set! container 'signal (make-signal (signal-ref signal)))
    (coroutine
     (let loop ()
       (wait step)
       (when (sample!)
         (loop))))
    (get)))

(define (signal-every step)
  "Create a new signal that emits STEP every STEP ticks."
  (signal-sample step (make-signal step)))

(define* (signal-timer #:optional (step 1))
  "Create a new signal that emits the total time elapsed since its
creation every STEP ticks."
  (signal-fold + 0 (signal-every step)))

(define (signal-since step signal)
  "Create a new signal that emits the time since SIGNAL was updated
every STEP ticks."
  (signal-map (lambda (time)
                (- (agenda-time) time))
              (signal-sample step (signal-time signal))))

(define (signal-delay delay signal)
  "Create a new signal that delays propagation of SIGNAL by DELAY
ticks."
  (make-boxed-signal (signal-ref signal)
                     (lambda (self value)
                       (schedule
                        (lambda ()
                          (%signal-set! self value))
                        delay))
                     (list signal)))

(define (signal-throttle delay signal)
  "Return a new signal that propagates SIGNAL at most once every DELAY
ticks."
  (make-boxed-signal (signal-ref signal)
                     (let ((last-time (agenda-time)))
                       (lambda (self value)
                         (when (>= (- (agenda-time) last-time) delay)
                           (%signal-set! self value)
                           (set! last-time (agenda-time)))))
                     (list signal)))

(define-syntax-parameter yield
  (lambda (form)
    (syntax-violation 'yield
                      "yield used outside of a signal-generator form"
                      form)))

(define-syntax-rule (signal-generator body ...)
  (let ((signal (make-signal #f)))
    (define (handler k value)
      (signal-set! signal value)
      (call-with-prompt 'signal-generator k handler))
    (coroutine
     (call-with-prompt
      'signal-generator
      (syntax-parameterize
          ((yield (syntax-rules ()
                    ((_ exp)
                     (abort-to-prompt 'signal-generator exp)))))
        (lambda () body ...))
      handler))
    signal))
