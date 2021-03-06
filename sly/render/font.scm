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
;; Font rendering.
;;
;;; Code:

(define-module (sly render font)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-2)
  #:use-module (srfi srfi-4)
  #:use-module (srfi srfi-9)
  #:use-module (system foreign)
  #:use-module ((sdl sdl) #:prefix SDL:)
  #:use-module ((sdl ttf) #:prefix SDL:)
  #:use-module (gl)
  #:use-module (sly wrappers gl)
  #:use-module (sly render color)
  #:use-module (sly config)
  #:use-module (sly render mesh)
  #:use-module (sly render sprite)
  #:use-module (sly render texture)
  #:export (enable-fonts
            load-font
            load-default-font
            font?
            font-point-size
            make-label label))

;;;
;;; Font
;;;

(define (enable-fonts)
  (SDL:ttf-init))

(define-record-type <font>
  (make-font ttf point-size)
  font?
  (ttf font-ttf)
  (point-size font-point-size))

(define (load-font filename point-size)
  "Load the TTF font in FILENAME with the given POINT-SIZE."
  (if (file-exists? filename)
      (make-font (SDL:load-font filename point-size) point-size)
      (error "File not found!" filename)))

(define* (load-default-font #:optional (point-size 12))
  "Load the Sly default TTF font.  POINT-SIZE is an optional
argument with a default value of 12."
  (load-font (string-append %pkgdatadir "/fonts/DejaVuSans.ttf") point-size))

(define (flip-pixels-vertically pixels width height)
  "Create a new bytevector that reverses the rows in PIXELS, a WIDTH x
HEIGHT, 32 bit color bytevector."
  (let ((buffer (make-u8vector (bytevector-length pixels)))
        (row-width (* width 4))) ; assuming 32 bit color
    (let loop ((y 0))
      (when (< y height)
        (let* ((y* (- height y 1))
               (source-start (* y row-width))
               (target-start (* y* row-width)))
          (bytevector-copy! pixels source-start buffer target-start row-width)
          (loop (1+ y)))))
    buffer))

(define (render-text font text)
  "Return a new texture with TEXT rendered using FONT."
  ;; An empty string will result in a surface value of #f, in which
  ;; case we want to abort the texture creation process.
  (and-let* ((surface (SDL:render-utf8 (font-ttf font) text
                                       (SDL:make-color 255 255 255) #t))
             (width (SDL:surface:w surface))
             (height (SDL:surface:h surface))
             ;; Need to flip pixels so that origin is on the bottom-left.
             (pixels (flip-pixels-vertically (SDL:surface-pixels surface)
                                             width height)))
    ;; Need to flip pixels so that origin is on the bottom-left.
    (bytevector->texture pixels width height 'linear 'linear)))

(define* (make-label font text #:optional #:key
                     (anchor 'top-left))
  (let ((texture (render-text font text)))
    (make-sprite texture #:anchor anchor)))

(define label make-label)
