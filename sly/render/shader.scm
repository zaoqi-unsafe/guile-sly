;;; Sly
;;; Copyright (C) 2014 David Thompson <dthompson2@worcester.edu>
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

(define-module (sly render shader)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 match)
  #:use-module (system foreign)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-4)
  #:use-module (srfi srfi-9)
  #:use-module (gl)
  #:use-module (gl low-level)
  #:use-module (sly utils)
  #:use-module (sly math transform)
  #:use-module (sly math vector)
  #:use-module (sly render color)
  #:use-module (sly config)
  #:use-module (sly wrappers gl)
  #:export (make-shader
            make-vertex-shader
            make-fragment-shader
            load-shader
            load-vertex-shader
            load-fragment-shader
            shader?
            vertex-shader?
            fragment-shader?
            shader-compiled?
            shader-type
            shader-id
            make-shader-program
            load-shader-program
            vertex-position-location
            vertex-texture-location
            shader-program-uniform-location
            shader-program-attribute-location
            shader-program-id
            shader-program?
            shader-program-linked?
            null-shader-program
            apply-shader-program
            with-shader-program
            load-default-shader
            %uniform-setters
            register-uniform-setter!
            uniform-set!
            uniforms))

(define-syntax-rule (define-logger name length-proc log-proc)
  (define (name obj)
    (let ((log-length (u32vector 0)))
      (length-proc obj (version-2-0 info-log-length)
                   (bytevector->pointer log-length))
      (let ((log (make-u8vector (1+ (u32vector-ref log-length 0)))))
        (log-proc obj (u32vector-ref log-length 0) %null-pointer
                  (bytevector->pointer log))
        (format #t "~a\n" (utf8->string log))))))

(define-syntax-rule (define-status name status-proc status-name)
  (define (name obj)
    (let ((status (u32vector 0)))
      (status-proc obj (version-2-0 status-name)
                   (bytevector->pointer status))
      (= (u32vector-ref status 0) 1))))

;;;
;;; Shaders
;;;

(define-record-type <shader>
  (%make-shader type id)
  shader?
  (type shader-type)
  (id shader-id))

(define (vertex-shader? shader)
  "Return #t if SHADER is a vertex shader, #f otherwise."
  (eq? (shader-type shader) 'vertex))

(define (fragment-shader? shader)
  "Return #t if SHADER is a fragment shader, #f otherwise."
  (eq? (shader-type shader) 'fragment))

(define-guardian shader-guardian
  (lambda (shader)
    (false-if-exception
     (glDeleteShader (shader-id shader)))))

;; Reap GL shaders when their wrapper objects are GC'd.
(define-guardian shader-guardian
  (lambda (shader)
    (false-if-exception (glDeleteShader (shader-id shader)))))

(define-status %shader-compiled? glGetShaderiv compile-status)

(define (shader-compiled? shader)
  (%shader-compiled? (shader-id shader)))

(define-logger %display-compilation-error glGetShaderiv glGetShaderInfoLog)

(define (display-compilation-error shader)
  (%display-compilation-error (shader-id shader)))

(define (compile-shader shader)
  "Attempt to compiler SHADER.  Compilation errors are written to
stdout."
  (glCompileShader (shader-id shader))
  (unless (shader-compiled? shader)
    (display "Failed to compile shader:\n")
    (display-compilation-error shader)))

(define (set-shader-source shader source)
  "Use the GLSL source code in the string SOURCE for SHADER."
  (let ((length (u32vector (string-length source)))
        (str (u64vector (pointer-address (string->pointer source)))))
    (glShaderSource (shader-id shader) 1 (bytevector->pointer str)
                    (bytevector->pointer length))))

(define (gl-shader-type type)
  "Convert the symbol TYPE to the appropriate OpenGL shader constant."
  (cond ((eq? type 'vertex)
         (version-2-0 vertex-shader))
        ((eq? type 'fragment)
         (version-2-0 fragment-shader))
        (else
         (error "Invalid shader type: " type))))

(define (make-shader type source)
  "Create a new GLSL shader of the given TYPE (vertex or fragment) and
compile the GLSL program contained in the string SOURCE."
  (let* ((id (glCreateShader (gl-shader-type type)))
         (shader (%make-shader type id)))
    (shader-guardian shader)
    (set-shader-source shader source)
    (compile-shader shader)
    shader))

(define (make-vertex-shader source)
  "Create a new GLSL vertex shader and compile the GLSL program
contained in the string SOURCE."
  (make-shader 'vertex source))

(define (make-fragment-shader source)
  "Create a new GLSL fragment shader and compile the GLSL program
contained in the string SOURCE."
  (make-shader 'fragment source))

(define (load-shader type filename)
  "Create a new GLSL shader of the given TYPE (vertex or fragment) and
compile the GLSL program stored in the file FILENAME."
  (if (file-exists? filename)
      (make-shader type (call-with-input-file filename read-string))
      (error "File not found!" filename)))

(define (load-vertex-shader filename)
  "Create a new GLSL vertex shader and compile the GLSL program stored
in the file FILENAME."
  (load-shader 'vertex filename))

(define (load-fragment-shader filename)
  "Create a new GLSL vertex shader and compile the GLSL program stored
in the file FILENAME."
  (load-shader 'fragment filename))

;;;
;;; Shader Programs
;;;

(define-record-type <uniform>
  (make-uniform name location)
  uniform?
  (name uniform-name)
  (location uniform-location))

(define-record-type <attribute>
  (make-attribute name location)
  attribute?
  (name attribute-name)
  (location attribute-location))

(define-record-type <shader-program>
  (%make-shader-program id uniforms attributes)
  shader-program?
  (id shader-program-id)
  (uniforms shader-program-uniforms)
  (attributes shader-program-attributes))

(define vertex-position-location 0)
(define vertex-texture-location 1)

(define (shader-program-uniform-location shader-program uniform-name)
  (let ((uniform (find (match-lambda
                        (($ <uniform> name _)
                         (string=? uniform-name name)))
                       (shader-program-uniforms shader-program))))
    (if uniform
        (uniform-location uniform)
        (error "Uniform not found: " uniform-name))))

(define (shader-program-attribute-location shader-program attribute-name)
  (let ((attribute (find (match-lambda
                          (($ <attribute> name _)
                           (string=? attribute-name name)))
                         (shader-program-attributes shader-program))))
    (if attribute
        (attribute-location attribute)
        (error "Attribute not found: " attribute-name))))

(define-guardian shader-program-guardian
  (lambda (shader-program)
    (false-if-exception
     (glDeleteProgram (shader-program-id shader-program)))))

(define-status shader-program-linked? glGetProgramiv link-status)
(define-logger display-linking-error glGetProgramiv glGetProgramInfoLog)

(define (make-shader-program vertex-shader fragment-shader uniforms attributes)
  "Create a new shader program that has been linked with the given
VERTEX-SHADER and FRAGMENT-SHADER."
  (unless (and (vertex-shader? vertex-shader)
               (fragment-shader? fragment-shader))
    (error "Expected a vertex shader and fragment shader"
           vertex-shader fragment-shader))
  (let ((id (glCreateProgram))
        (shaders (list vertex-shader fragment-shader)))
    (define (string->uniform uniform-name)
      (let ((location (glGetUniformLocation id uniform-name)))
        (if (= location -1)
            (error "Uniform not found: " uniform-name)
            (make-uniform uniform-name location))))

    (define (string->attribute attribute-name)
      (let ((location (glGetAttribLocation id attribute-name)))
        (if (= location -1)
            (error "Attribute not found: " attribute-name)
            (make-attribute attribute-name location))))

    (catch #t
      (lambda ()
        (for-each (lambda (shader)
                    (glAttachShader id (shader-id shader)))
                  shaders)
        ;; Bind attribute locations
        (glBindAttribLocation id vertex-position-location "position")
        (glBindAttribLocation id vertex-texture-location "tex")
        (glLinkProgram id)
        (unless (shader-program-linked? id)
          (display "Failed to link shader program:\n")
          (display-linking-error id))
        ;; Once the program has been linked, the shaders can be detached.
        (for-each (lambda (shader)
                    (glDetachShader id (shader-id shader)))
                  shaders)
        (let* ((uniforms (map string->uniform uniforms))
               (attributes (map string->attribute attributes))
               (shader-program (%make-shader-program id uniforms attributes)))
          (shader-program-guardian shader-program)
          shader-program))
      throw
      (lambda _
        ;; Make sure to delete program in case linking fails.
        (glDeleteProgram id)))))

(define (load-shader-program vertex-shader-file-name fragment-shader-file-name
                             uniforms attributes)
  (make-shader-program (load-vertex-shader vertex-shader-file-name)
                       (load-fragment-shader fragment-shader-file-name)
                       uniforms attributes))

(define null-shader-program
  (%make-shader-program 0 '() '()))

(define (apply-shader-program shader-program)
  (glUseProgram (shader-program-id shader-program)))

(define-syntax-rule (with-shader-program shader-program body ...)
  "Evaluate BODY with SHADER-PROGRAM bound."
  (parameterize ((current-shader-program shader-program))
    (begin
      (apply-shader-program shader-program)
      (let ((return-value (begin body ...)))
        (glUseProgram 0)
        return-value))))

(define load-default-shader
  (memoize
   (lambda ()
     (load-shader-program
      (string-append %pkgdatadir
                     "/shaders/default-vertex.glsl")
      (string-append %pkgdatadir
                     "/shaders/default-fragment.glsl")
      '("mvp" "color" "use_texture")
      '("position" "tex")))))

;;;
;;; Uniforms
;;;

(define-record-type <uniform-setter>
  (make-uniform-setter predicate proc)
  uniform-setter?
  (predicate uniform-setter-predicate)
  (proc uniform-setter-proc))

(define %uniform-setters '())

(define (register-uniform-setter! predicate setter)
  "Add a new type of uniform setter for shader programs where
PREDICATE tests the type of a given value and SETTER performs the
necessary OpenGL calls to set the uniform value in the proper
location."
  (set! %uniform-setters
        (cons (make-uniform-setter predicate setter)
              %uniform-setters)))

;; Built-in uniform setters for booleans, numbers, vectors, and
;; colors.
(register-uniform-setter! boolean?
                          (lambda (location b)
                            (glUniform1i location (if b 1 0))))

(register-uniform-setter! number?
                          (lambda (location n)
                            (glUniform1f location n)))

(register-uniform-setter! vector2?
                          (lambda (location v)
                            (glUniform2f location (vx v) (vy v))))

(register-uniform-setter! vector3?
                          (lambda (location v)
                            (glUniform3f location (vx v) (vy v) (vz v))))

(register-uniform-setter! vector4?
                          (lambda (location v)
                            (glUniform4f location (vx v) (vy v) (vz v) (vw v))))

(register-uniform-setter! transform?
                          (lambda (location t)
                            (let ((pointer
                                   (bytevector->pointer
                                    (array-contents (transform-matrix t)))))
                              (glUniformMatrix4fv location 1 #f
                                                  pointer))))

(register-uniform-setter! color?
                          (lambda (location c)
                            (glUniform4f location
                                         (color-r c)
                                         (color-g c)
                                         (color-b c)
                                         (color-a c))))

(define (uniform-set! shader-program name value)
  "Use the appropriate setter procedure to translate VALUE into OpenGL
compatible data and assign it to the location of the uniform NAME
within SHADER-PROGRAM."
  (let ((setter (find (lambda (setter)
                        ((uniform-setter-predicate setter) value))
                      %uniform-setters))
        (location (shader-program-uniform-location shader-program name)))
    (if setter
        ((uniform-setter-proc setter) location value)
        (error "Not a valid uniform data type" value))))

;; Bind values to uniform variables within the current shader program
;; via a let-style syntax.  The types of the given values must be
;; accounted for in the %uniform-setters list.  This macro simply sets
;; uniform values and does not restore the previous values after
;; evaluating the body of the form.
;;
;; emacs: (put 'uniforms 'scheme-indent-function 1)
(define-syntax uniforms
  (syntax-rules ()
    ((_ () body ...)
     (begin body ...))
    ((_ ((name value) ...) body ...)
     (begin
       (uniform-set! (current-shader-program) 'name value)
       ...
       body ...))))
