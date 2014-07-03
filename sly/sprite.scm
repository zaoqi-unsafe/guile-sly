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
;; Sprites are typically the most important part of a 2D game. This
;; module provides sprites as an abstraction around OpenGL textures.
;;
;;; Code:

(define-module (sly sprite)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (gl)
  #:use-module (gl contrib packed-struct)
  #:use-module ((sdl sdl) #:prefix SDL:)
  #:use-module (sly agenda)
  #:use-module (sly animation)
  #:use-module (sly color)
  #:use-module (sly config)
  #:use-module (sly helpers)
  #:use-module (sly math)
  #:use-module (sly shader)
  #:use-module (sly signal)
  #:use-module (sly texture)
  #:use-module (sly vector)
  #:use-module (sly window)
  #:use-module (sly wrappers gl)
  #:export (enable-sprites
            make-sprite
            sprite?
            animated-sprite?
            sprite-drawable
            sprite-position
            sprite-scale
            sprite-rotation
            sprite-color
            sprite-anchor
            set-sprite-drawable
            set-sprite-position
            set-sprite-scale
            set-sprite-rotation
            set-sprite-color
            set-sprite-anchor
            load-sprite
            draw-sprite))

;;;
;;; Sprites
;;;

(define sprite-shader #f)

(define (enable-sprites)
  (set! sprite-shader
        (load-shader-program
         (string-append %pkgdatadir
                        "/shaders/sprite-vertex.glsl")
         (string-append %pkgdatadir
                        "/shaders/sprite-fragment.glsl"))))

;; The <sprite> type represents a drawable object (texture,
;; texture-region, animation, etc.) with a given position, scale,
;; rotation, and color.
(define-immutable-record-type <sprite>
  (%make-sprite drawable position scale rotation color anchor vertices animator)
  sprite?
  (drawable sprite-drawable set-sprite-drawable)
  (position %sprite-position set-sprite-position)
  (scale %sprite-scale set-sprite-scale)
  (rotation %sprite-rotation set-sprite-rotation)
  (color %sprite-color set-sprite-color)
  (anchor sprite-anchor set-sprite-anchor)
  (vertices sprite-vertices)
  (animator sprite-animator))

(define sprite-position (compose signal-ref-maybe %sprite-position))
(define sprite-scale (compose signal-ref-maybe %sprite-scale))
(define sprite-rotation (compose signal-ref-maybe %sprite-rotation))
(define sprite-color (compose signal-ref-maybe %sprite-color))

(define (update-sprite-vertices! sprite)
  (let ((texture (sprite-texture sprite)))
    (pack-texture-vertices (sprite-vertices sprite)
                           0
                           (texture-width texture)
                           (texture-height texture)
                           (texture-s1 texture)
                           (texture-t1 texture)
                           (texture-s2 texture)
                           (texture-t2 texture))))

(define* (make-sprite drawable #:optional #:key
                      (position #(0 0)) (scale #(1 1))
                      (rotation 0) (color white) (anchor 'center))
  "Create a new sprite object. DRAWABLE is either a texture or
animation object.  All keyword arguments are optional. POSITION is a
vector with a default of (0, 0).  SCALE is a vector that describes how
much DRAWABLE should be strected on the x and y axes, with a default
of 1x scale.  ROTATION is an angle in degrees with a default of 0.
COLOR is a color object with a default of white.  ANCHOR is either a
vector that represents the center point of the sprite, or 'center
which will place the anchor at the center of DRAWABLE.  Sprites are
centered by default."
  (let* ((vertices (make-packed-array texture-vertex 4))
         (animator (if (animation? drawable)
                       (make-animator drawable)
                       #f))
         (anchor (anchor-texture (drawable-texture drawable animator) anchor))
         (sprite (%make-sprite drawable position scale rotation color
                               anchor vertices animator)))
    (update-sprite-vertices! sprite)
    sprite))

(define* (load-sprite filename #:optional #:key
                      (position #(0 0)) (scale #(1 1))
                      (rotation 0) (color white) (anchor 'center))
  "Load a sprite from the file at FILENAME. See make-sprite for
optional keyword arguments."
  (make-sprite (load-texture filename)
               #:position position
               #:scale scale
               #:rotation rotation
               #:color color
               #:anchor anchor))

(define (animated-sprite? sprite)
  "Return #t if SPRITE has an animation as its drawable object."
  (animation? (sprite-drawable sprite)))

(define (drawable-texture drawable animator)
  (cond ((texture? drawable)
         drawable)
        ((animation? drawable)
         (animator-texture animator))))

(define (sprite-texture sprite)
  "Return the texture for the SPRITE's drawable object."
  (let ((drawable (sprite-drawable sprite)))
    (drawable-texture (sprite-drawable sprite)
                      (sprite-animator sprite))))

(define (update-sprite-animator! sprite)
  (animator-update! (sprite-animator sprite))
  (update-sprite-vertices! sprite))

(define (draw-sprite sprite)
  "Render SPRITE to the screen. A sprite batch will be used if one is
currently bound."
  (register-animated-sprite-maybe sprite)
  (with-shader-program sprite-shader
    (uniforms ((position (sprite-position sprite))
               (anchor (sprite-anchor sprite))
               (scale (sprite-scale sprite))
               (rotation (sprite-rotation sprite))
               (color (sprite-color sprite))
               (projection (signal-ref window-projection)))
      (draw-texture-vertices (sprite-texture sprite)
                             (sprite-vertices sprite)
                             1))))

;; A hash table for all of the animated sprites that have been drawn
;; since the last game update.  It is cleared after every agenda tick.
(define animated-sprites (make-hash-table))

(define (register-animated-sprite-maybe sprite)
  (when (animated-sprite? sprite)
    (hash-set! animated-sprites sprite sprite)))

(define (update-animated-sprites!)
  "Update all animators for sprites that have been drawn this frame."
  (hash-for-each (lambda (key val)
                   (update-sprite-animator! val))
                 animated-sprites)
  (hash-clear! animated-sprites))

;; Update animated sprites upon every update.
(schedule-each update-animated-sprites!)