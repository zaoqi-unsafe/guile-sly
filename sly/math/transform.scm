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

;;; Commentary:
;;
;; 4x4 column-major transformation matrix.
;;
;;; Code:

(define-module (sly math transform)
  #:use-module (system foreign)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-42)
  #:use-module (sly math)
  #:use-module (sly math vector)
  #:use-module (sly math quaternion)
  #:use-module (sly wrappers gsl)
  #:export (make-transform null-transform identity-transform
            transform? transform-matrix
            transpose transform-vector2
            transform-position
            transform+ transform* transform*!
            scale translate rotate-x rotate-y rotate-z rotate
            build-transform
            orthographic-projection perspective-projection
            look-at))

(define-record-type <transform>
  (%make-transform matrix)
  transform?
  (matrix transform-matrix))

(define (make-4x4-matrix)
  (make-typed-array 'f32 0 4 4))

(define (make-transform aa ab ac ad
                        ba bb bc bd
                        ca cb cc cd
                        da db dc dd)
  "Return a new transform initialized with the given 16 values in
column-major format."
  (let ((matrix (make-4x4-matrix)))
    (array-set! matrix aa 0 0)
    (array-set! matrix ab 0 1)
    (array-set! matrix ac 0 2)
    (array-set! matrix ad 0 3)
    (array-set! matrix ba 1 0)
    (array-set! matrix bb 1 1)
    (array-set! matrix bc 1 2)
    (array-set! matrix bd 1 3)
    (array-set! matrix ca 2 0)
    (array-set! matrix cb 2 1)
    (array-set! matrix cc 2 2)
    (array-set! matrix cd 2 3)
    (array-set! matrix da 3 0)
    (array-set! matrix db 3 1)
    (array-set! matrix dc 3 2)
    (array-set! matrix dd 3 3)
    (%make-transform matrix)))

(define null-transform
  (%make-transform (make-4x4-matrix)))

(define identity-transform
  (make-transform 1 0 0 0
                  0 1 0 0
                  0 0 1 0
                  0 0 0 1))

(define (transpose transform)
  "Return a transform that is the transpose of TRANSFORM."
  (let ((m1 (transform-matrix transform))
        (m2 (make-4x4-matrix)))
    (do-ec (: r 4) (: c 4)
           (array-set! m2 (array-ref m1 r c)
                       c r))
    (%make-transform m2)))

(define (transform-vector2 transform v)
  "Apply TRANSFORM to the 2D vector V."
  (let ((m (transform-matrix transform))
        (x (vx v))
        (y (vy v)))
    (vector2 (+ (* x (array-ref m 0 0))
                (* y (array-ref m 0 1))
                (array-ref m 0 3))
             (+ (* x (array-ref m 1 0))
                (* y (array-ref m 1 1))
                (array-ref m 1 3)))))

(define (transform-position transform)
  "Return a vector3 containing the positional data stored in
TRANSFORM."
  (let ((matrix (transform-matrix transform)))
    (vector3 (array-ref matrix 3 0)
             (array-ref matrix 3 1)
             (array-ref matrix 3 2))))

(define (transform+ . transforms)
  "Return the sum of TRANSFORM.  Return 'null-transform' if called
without any arguments."
  (define (add a b)
    (let ((m1 (transform-matrix a))
          (m2 (transform-matrix b))
          (m3 (make-4x4-matrix)))
      (do-ec (: r 4) (: c 4)
             (let ((x (+ (array-ref m1 r c)
                         (array-ref m2 r c))))
               (array-set! m3 x r c)))
      (%make-transform m3)))
  (reduce add null-transform transforms))

(define (transform->pointer t)
  (bytevector->pointer (array-contents (transform-matrix t))))

(define (transform* . transforms)
  "Return the product of TRANSFORMS.  Return identity-transform if
called without any arguments."
  (define (mul a b)
    (let ((result (%make-transform (make-4x4-matrix))))
      (transform*! result a b)
      result))
  (reduce mul identity-transform transforms))

(define (transform*! dest a b)
  (cblas-sgemm cblas-row-major cblas-no-trans cblas-no-trans
               4 4 4 1
               (transform->pointer a) 4
               (transform->pointer b) 4
               0 (transform->pointer dest) 4))

(define translate
  (match-lambda
    (($ <vector2> x y)
     (make-transform  1 0 0 0
                      0 1 0 0
                      0 0 1 0
                      x y 0 1))
    (($ <vector3> x y z)
     (make-transform 1 0 0 0
                     0 1 0 0
                     0 0 1 0
                     x y z 1))
    (v (error "Invalid translation vector: " v))))

(define scale
  (match-lambda
   ((? number? v)
    (make-transform v 0 0 0
                    0 v 0 0
                    0 0 v 0
                    0 0 0 1))
   (($ <vector2> x y)
    (make-transform x 0 0 0
                    0 y 0 0
                    0 0 1 0
                    0 0 0 1))
   (($ <vector3> x y z)
    (make-transform x 0 0 0
                    0 y 0 0
                    0 0 z 0
                    0 0 0 1))
   (v (error "Invalid scaling vector: " v))))

(define (rotate-x angle)
  "Return a new transform that rotates the X axis by ANGLE radians."
  (make-transform 1 0           0               0
                  0 (cos angle) (- (sin angle)) 0
                  0 (sin angle) (cos angle)     0
                  0 0           0               1))

(define (rotate-y angle)
  "Return a new transform that rotates the Y axis by ANGLE radians."
  (make-transform (cos angle)     0 (sin angle) 0
                  0               1 0           0
                  (- (sin angle)) 0 (cos angle) 0
                  0               0 0           1))

(define (rotate-z angle)
  "Return a new transform that rotates the Z axis by ANGLE radians."
  (make-transform (cos angle) (- (sin angle)) 0 0
                  (sin angle) (cos angle)     0 0
                  0           0               1 0
                  0           0               0 1))

(define rotate
  (match-lambda
   (($ <quaternion> w x y z)
    (make-transform
     (- 1 (* 2 (square y)) (* 2 (square z)))
     (- (* 2 x y) (* 2 w z))
     (+ (* 2 x z) (* 2 w y))
     0
     (+ (* 2 x y) (* 2 w z))
     (- 1 (* 2 (square x)) (* 2 (square z)))
     (- (* 2 y z) (* 2 w x))
     0
     (- (* 2 x z) (* 2 w y))
     (+ (* 2 y z) (* 2 w x))
     (- 1 (* 2 (square x)) (* 2 (square y)))
     0 0 0 0 1))))

(define build-transform
  (let ((%scale scale))
    (lambda* (#:optional #:key (position (vector3 0 0 0))
              (scale 1) (rotation null-quaternion))
      (transform* (translate position)
                  (%scale scale)
                  (rotate rotation)))))

(define (orthographic-projection left right top bottom near far)
  "Return a new transform that represents an orthographic projection
for the vertical clipping plane LEFT and RIGHT, the horizontal
clipping plane TOP and BOTTOM, and the depth clipping plane NEAR and
FAR."
  (make-transform (/ 2 (- right left)) 0 0 0
                  0 (/ 2 (- top bottom)) 0 0
                  0 0 (/ 2 (- far near)) 0
                  (- (/ (+ right left) (- right left)))
                  (- (/ (+ top bottom) (- top bottom)))
                  (- (/ (+ far near) (- far near)))
                  1))

(define (perspective-projection field-of-vision aspect-ratio near far)
  "Return a new transform that represents a perspective projection
with a FIELD-OF-VISION in degrees, the desired ASPECT-RATIO, and the
depth clipping plane NEAR and FAR."
  (let ((f (cotan (/ (degrees->radians field-of-vision) 2))))
    (make-transform (/ f aspect-ratio) 0 0 0
                    0 f 0 0
                    0 0 (/ (+ far near) (- near far)) -1
                    0 0 (/ (* 2 far near) (- near far)) 0)))

(define* (look-at eye center #:optional (up (vector3 0 1 0)))
  (let* ((forward (normalize (v- center eye)))
         (side (normalize (vcross forward up)))
         (up (normalize (vcross side forward))))
    (transform*
     (make-transform (vx side) (vx up) (- (vx forward)) 0
                     (vy side) (vy up) (- (vy forward)) 0
                     (vz side) (vz up) (- (vz forward)) 0
                     0         0       0                1)
     (translate (v- eye)))))
