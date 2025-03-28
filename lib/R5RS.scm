;;   __ __                          __
;;  / / \ \       _    _  ___  ___  \ \
;; | |   \ \     | |  | || . \/ __>  | |
;; | |    > \    | |_ | ||  _/\__ \  | |
;; | |   / ^ \   |___||_||_|  <___/  | |
;;  \_\ /_/ \_\                     /_/
;;
;; <https://lips.js.org>
;;
;; Attempt to implement R5RS standard on top of LIPS
;;
;; Reference:
;; https://schemers.org/Documents/Standards/R5RS/HTML/
;;
;; This file is part of the LIPS - Scheme based Powerful lisp in JavaScript
;; Copyright (C) 2019-2024 Jakub T. Jankiewicz <https://jcubic.pl/me>
;; Released under MIT license
;;
;; (+ 1 (call-with-current-continuation
;;       (lambda (escape)
;;         (+ 2 (escape 3)))))
;;
;; -----------------------------------------------------------------------------
(define string-append concat)
(define = ==)
(define remainder %)
(define procedure? function?)
(define expt **)
(define list->vector list->array)
(define vector->list array->list)
(define call-with-current-continuation call/cc)

;; -----------------------------------------------------------------------------
(define (procedure? obj)
  "(procedure? expression)

   Predicate that tests if value is a callable function or continuation."
  (or (function? obj) (continuation? obj)))

;; -----------------------------------------------------------------------------
(define-macro (define-symbol-macro type spec . rest)
  "(define-symbol-macro type (name . args) . body)

   Creates syntax extensions for evaluator similar to built-in , or `.
   It's like an alias for a real macro. Similar to CL reader macros
   but it receives already parsed code like normal macros. Type can be SPLICE
   or LITERAL symbols (see set-special!). ALL default symbol macros are literal."
  (let* ((name (car spec))
         (symbol (cadr spec))
         (args (cddr spec)))
     `(begin
        (set-special! ,symbol ',name ,(string->symbol
                                       (concat "lips.specials."
                                               (symbol->string type))))
        (define-macro (,name ,@args) ,@rest))))

;; -----------------------------------------------------------------------------
;; Vector literals syntax using parser syntax extensions
;; -----------------------------------------------------------------------------
(define-symbol-macro SPLICE (vector-literal "#" . args)
  (if (not (or (pair? args) (eq? args '())))
      (throw (new Error (concat "Parse Error: vector require pair got "
                                (type args) " in " (repr args))))
      (let ((v (list->array args)))
        (Object.freeze v)
        v)))

;; -----------------------------------------------------------------------------
(define (vector . rest)
  "(vector 1 2 3 (+ 3 1)) or #(1 2 3 4)

   Macro for defining vectors (Javascript Arrays). Vector literals are
   automatically quoted, so you can't use expressions inside them, only other
   literals, like other vectors or objects."
  (list->array rest))

;; -----------------------------------------------------------------------------
(set-repr! Array
           (lambda (arr q)
             ;; Array.from is used to convert empty to undefined
             ;; but we can't use the value because Array.from calls
             ;; valueOf on its arguments (unbox the LIPS data types)
             (let ((result (--> (Array.from arr)
                                (map (lambda (x i)
                                       (if (not (in i arr))
                                           "#<empty>"
                                           (repr (. arr i) q)))))))
               (concat "#(" (--> result (join " ")) ")"))))

;; -----------------------------------------------------------------------------
(define (eqv? a b)
  "(eqv? a b)

   Function that compares the values. It returns true if they are the same, they
   need to have the same type."
  (if (string=? (type a) (type b))
      (cond ((number? a)
             (or (and (exact? a) (exact? b) (= a b))
                 (and (inexact? a)
                      (inexact? b)
                      (cond ((a.isNaN) (b.isNaN))
                            ((and (zero? a) (zero? b))
                             (eq? a._minus b._minus))
                            ((and (complex? a) (complex? b))
                             (let ((re.a (real-part a))
                                   (re.b (real-part b))
                                   (im.a (imag-part a))
                                   (im.b (imag-part b)))
                               (and
                                (if (and (zero? re.a) (zero? re.b))
                                    (eq? (. re.a '_minus) (. re.b '_minus))
                                    true)
                                (if (and (zero? im.a) (zero? im.b))
                                    (eq? (. im.a '_minus) (. im.b '_minus))
                                    true)
                                (or (= re.a re.b)
                                    (and (--> re.a (isNaN))
                                         (--> re.b (isNaN))))
                                (or (= im.a im.b)
                                    (and (--> im.a (isNaN))
                                         (--> im.b (isNaN)))))))
                            (else (= a b))))))
            ((and (pair? a) (null? a)) (null? b))
            (else (eq? a b)))
      false))

;; -----------------------------------------------------------------------------
(define (equal? a b)
  "(equal? a b)

   The function checks if values are equal. If both are a pair or an array
   it compares their elements recursively. If pairs have cycles it compares
   them with eq?"
  (cond ((and (pair? a))
         (and (pair? b)
              (equal? (car a) (car b))
              (equal? (cdr a) (cdr b))))
        ((symbol? a)
         (and (symbol? b)
              (equal? a.__name__ b.__name__)))
        ((regex? a)
         (and (regex? b)
              (equal? (. a 'source) (. b 'source))))
        ((typed-array? a)
         (and (typed-array? b)
              (equal? (Array.from a) (Array.from b))))
        ((vector? a)
         (and (vector? b)
              (= (length a) (length b))
              (--> a (every (lambda (item i)
                              (equal? item (vector-ref b i)))))))
        ((string? a)
         (and (string? b)
              (string=? a b)))
        ((function? a)
         (and (function? b)
              (%same-functions a b)))
        ((array? a)
         (and (array? b)
              (eq? (length a) (length b))
              (= (--> a (filter (lambda (item i)
                                  (equal? item (. b i))))
                      'length)
                 (length a))))
        ((plain-object? a)
         (and (plain-object? b)
              (let ((keys_a (--> (Object.keys a) (sort)))
                    (keys_b (--> (Object.keys b) (sort))))
                (and (= (length keys_a)
                        (length keys_b))
                     (equal? keys_a keys_b)
                     (equal? (--> keys_a (map (lambda (key) (. a key))))
                             (--> keys_b (map (lambda (key) (. b key)))))))))
        ((instance? a)
         (and (instance? b)
              (%same-functions b.constructor a.constructor)
              (function? a.equal)
              (a.equal b)))
        (else (eqv? a b))))

;; -----------------------------------------------------------------------------
(define make-promise
  (lambda (proc)
    "(make-promise fn)

     Function that creates a promise from a function."
    (typecheck "make-promise" proc "function")
    (let ((result-ready? #f)
          (result #f))
      (let ((promise (lambda ()
                       (if result-ready?
                           result
                           (let ((x (proc)))
                             (if result-ready?
                                 result
                                 (begin (set! result-ready? #t)
                                        (set! result x)
                                        result)))))))
        (set-obj! promise (Symbol.for "promise") true)
        (set! promise.toString (lambda ()
                                 (string-append "#<promise - "
                                                (if result-ready?
                                                    (string-append "forced with "
                                                                   (type result))
                                                    "not forced")
                                                ">")))
        promise))))

;; -----------------------------------------------------------------------------
(define-macro (delay expression)
  "(delay expression)

   Will create a promise from expression that can be forced with (force)."
  `(make-promise (lambda () ,expression)))

;; -----------------------------------------------------------------------------
(define (force promise)
  "(force promise)

   Function that forces the promise and evaluates the delayed expression."
  (promise))

;; -----------------------------------------------------------------------------
(define (promise? obj)
  "(promise? obj)

   Checks if the value is a promise created with delay or make-promise."
  (and (string=? (type obj) "function")
       (. obj (Symbol.for "promise"))))

;; -----------------------------------------------------------------------------
(define (positive? x)
  "(positive? x)

   Checks if the number is larger then 0"
  (typecheck "positive?" x "number")
  (> x 0))

;; -----------------------------------------------------------------------------
(define (negative? x)
  "(negative? x)

   Checks if the number is smaller then 0"
  (typecheck "negative?" x "number")
  (< x 0))

;; -----------------------------------------------------------------------------
(define (zero? x)
  "(zero? x)

   Checks if the number is equal to 0"
  (typecheck "zero?" x "number")
  (= x 0))

;; -----------------------------------------------------------------------------
(define (quotient a b)
  "(quotient a b)

   Return quotient from division as integer."
  (typecheck "quotient" a "number")
  (typecheck "quotient" b "number")
  (if (zero? b 0)
     (throw (new Error "quotient: division by zero"))
     (let ((quotient (/ a b)))
       (if (integer? quotient)
           quotient
           (if (> quotient 0)
               (floor quotient)
               (ceiling quotient))))))

;; -----------------------------------------------------------------------------
(define (number->string x . rest)
  "(number->string x [radix])

   Function that converts number to string with optional radix (number base)."
  (typecheck "number->string" x "number" 1)
  (let ((radix (if (null? rest) 10 (car rest))))
    (typecheck "number->string" radix "number" 2)
    (--> x (toString (--> radix (valueOf))))))

;; -----------------------------------------------------------------------------
(define (boolean? x)
  "(boolean? x)

   Returns true if value is boolean."
   (string=? (type x) "boolean"))

;; -----------------------------------------------------------------------------
(define (vector-ref vector i)
  "(vector-ref vector i)

   Return i-th element from vector."
  (typecheck "number->string" vector "array" 1)
  (typecheck "number->string" i "number" 2)
  (. vector i))

;; -----------------------------------------------------------------------------
(define (vector-set! vector i obj)
  "(vector-set! vector i obj)

   Set obj as value in vector at position i."
  (typecheck "vector-set!" vector "array" 1)
  (typecheck "vector-set!" i "number" 2)
  (set-obj! vector i obj))

;; -----------------------------------------------------------------------------
(define (%number-type type x)
  (typecheck "%number-type" type (vector "string" "pair"))
  (typecheck "%number-type" x "number")
  (let* ((t x.__type__)
         (typeof (lambda (type) (string=? t type))))
    (and (number? x)
         (if (pair? type)
             (some typeof type)
             (typeof type)))))


;; -----------------------------------------------------------------------------
(define (real? x)
  "(real? x)

   Checks if the argument x is real."
  (and (number? x) (or (eq? x NaN)
                       (eq? x Number.NEGATIVE_INFINITY)
                       (eq? x Number.POSITIVE_INFINITY)
                       (and (%number-type "complex" x)
                            (let ((i (imag-part x)))
                              (and (zero? i) (exact? i))))
                       (%number-type '("float" "bigint" "rational") x))))

;; -----------------------------------------------------------------------------
(define (integer? x)
  "(integer? x)

  Checks if the argument x is integer."
  (and (number? x)
       (not (eq? x NaN))
       (not (eq? x Number.NEGATIVE_INFINITY))
       (not (eq? x Number.POSITIVE_INFINITY))
       (or (%number-type "bigint" x)
           (%number-type "integer" x)
           (and (%number-type "float" x)
                (= (modulo x 2) 1)))))

;; -----------------------------------------------------------------------------
(define (complex? x)
  "(complex? x)

  Checks if argument x is complex."
  (and (number? x) (or (eq? x NaN)
                       (eq? x Number.NEGATIVE_INFINITY)
                       (eq? x Number.POSITIVE_INFINITY)
                       (%number-type '("complex" "float" "bigint" "rational") x))))

;; -----------------------------------------------------------------------------
(define (rational? x)
  "(rational? x)

  Checks if the value is rational."
  (and (number? x)
       (not (eq? x NaN))
       (not (eq? x Number.NEGATIVE_INFINITY))
       (not (eq? x Number.POSITIVE_INFINITY))
       (or (%number-type "rational" x) (integer? x))))

;; -----------------------------------------------------------------------------
(define (typecheck-args _type label _list)
  "(typecheck-args type label lst)

   Function that makes sure that all items in list are of same type."
  (let iter ((n 1) (_list _list))
    (if (pair? _list)
        (begin
          (typecheck label (car _list) _type n)
          (iter (+ n 1) (cdr _list))))))

;; -----------------------------------------------------------------------------
(define numbers? (curry typecheck-args "number"))

;; -----------------------------------------------------------------------------
(define (max . args)
  "(max n1 n2 ...)

   Returns the maximum of its arguments."
  (numbers? "max" args)
  (apply Math.max args))

;; -----------------------------------------------------------------------------
(define (min . args)
  "(min n1 n2 ...)

   Returns the minimum of its arguments."
  (numbers? "min" args)
  (apply Math.min args))

;; -----------------------------------------------------------------------------
(define (make-rectangular re im)
  "(make-rectangular im re)

   Creates a complex number from imaginary and real part (a+bi form)."
  (let ((value `((re . ,re) (im . ,im))))
    (lips.LComplex (--> value (to_object true)))))

;; -----------------------------------------------------------------------------
(define (exact? n)
  "(exact? n)"
  (typecheck "exact?" n "number")
  (let ((type n.__type__))
    (or (string=? type "bigint")
        (string=? type "rational")
        (and (string=? type "complex")
             (exact? n.__im__)
             (exact? n.__re__)))))

;; -----------------------------------------------------------------------------
(define (inexact? n)
  "(inexact? n)"
  (typecheck "inexact?" n "number")
  (not (exact? n)))

;; -----------------------------------------------------------------------------
(define (exact->inexact n)
  "(exact->inexact n)

   Convert exact number to inexact."
  (typecheck "exact->inexact" n "number")
  (if (%number-type "complex" n)
      (lips.LComplex (object :im (exact->inexact (. n '__im__))
                             :re (exact->inexact (. n '__re__))))
      (if (or (rational? n) (integer? n))
          (lips.LFloat (--> n (valueOf)) true)
          n)))

;; -----------------------------------------------------------------------------
(define (inexact->exact n)
  "(inexact->exact number)

   Function that converts real number to exact rational number."
  (typecheck "inexact->exact" n "number")
  (if (exact? n)
      n
      (--> n (toRational))))

;; -----------------------------------------------------------------------------
(define (log z)
  "(log z)

   Function that calculates natural logarithm of z where the argument can be
   any number (including complex negative and rational).
   If the value is 0 it return NaN."
  (cond ((real? z)
         (cond ((zero? z) NaN)
               ((> z 0) (Math.log z))
               (else
                (+ (Math.log (abs z))
                   (* Math.PI +i)))))
        ((complex? z)
         (let ((arg (Math.atan2 (imag-part z)
                                (real-part z))))
           (+ (Math.log (z.modulus))
              (* +i arg))))
        ((rational? z)
         (log (exact->inexact z)))))

;; -----------------------------------------------------------------------------
;; generate Math functions with documentation
(define _maths (list "asin" "acos"))

;; -----------------------------------------------------------------------------
(define _this_env (current-environment))

;; -----------------------------------------------------------------------------
(let iter ((fns _maths))
  (if (not (null? fns))
      (let* ((name (car fns))
             (op (. Math name))
             (fn (lambda (n) (lips.LNumber (op n)))))
        (--> _this_env (set name fn))
        (set-obj! fn '__doc__ (concat "(" name " n)\n\nFunction that calculates " name
                                  " math operation (it call JavaScript Math." name
                                  " function)"))
        (iter (cdr fns)))))

;; -----------------------------------------------------------------------------
(define (sin n)
  "(sin n)

  Function that calculates sine of a number."
  (typecheck "sin" n "number")
  (if (string=? n.__type__ "complex")
      (let ((re (real-part n))
            (im (imag-part n)))
        (lips.LComplex (object :re (* (Math.sin re)
                                      (Math.cosh im))
                               :im (* (Math.cos re)
                                      (Math.sinh im)))))
      (Math.sin n)))

;; -----------------------------------------------------------------------------
(define (cos n)
  "(cos n)

  Function that calculates cosine of a number."
  (typecheck "cos" n "number")
  (if (string=? n.__type__ "complex")
      (let ((re (real-part n))
            (im (imag-part n)))
        (lips.LComplex (object :re (* (Math.cos re)
                                      (Math.cosh im))
                               :im (- (* (Math.sin re)
                                         (Math.sinh im))))))
      (Math.cos n)))

;; -----------------------------------------------------------------------------
(define (tan n)
  "(tan n)

  Function that calculates tangent of a number."
  (typecheck "tan" n "number")
  (if (string=? n.__type__ "complex")
      (let* ((re (real-part n))
             (im (imag-part n))
             (re2 (* 2 re))
             (im2 (* 2 im)))
        (lips.LComplex (object :re (/ (Math.sin re2)
                                      (+ (Math.cos re2)
                                         (Math.cosh im2)))
                               :im (/ (Math.sinh im2)
                                      (+ (Math.cos re2)
                                         (Math.cosh im2))))))
      (Math.tan n)))

;; -----------------------------------------------------------------------------
(define (atan z . rest)
  "(atan z)
   (atan x y)

   Function calculates arcus tangent of a complex number.
   If two arguments are passed and they are not complex numbers
   it calculate Math.atan2 on those arguments."
  (if (and (null? rest) (complex? z))
      (cond ((nan? z) +nan.0)
            ((infinite? z)
             (let ((atan (/ Math.PI 2)))
               (if (< z 0)
                   (- atan)
                   atan)))
            (else
             ;; ref: https://youtu.be/d93AarE0lKg
             (let ((iz (* +i z)))
               (* (/ 1 +2i)
                  (log (/ (+ 1 iz)
                          (- 1 iz)))))))
      (let ((x z) (y (car rest)))
        (if (and (zero? (imag-part x))
                 (zero? (imag-part y)))
            (Math.atan2 x y)
            (error "atan: can't call with two complex numbers")))))

;; -----------------------------------------------------------------------------
(define (exp n)
  "(exp n)

  Function that calculates e raised to the power of n."
  (typecheck "exp" n "number")
  (if (string=? n.__type__ "complex")
      (let* ((re (real-part n))
             (im (imag-part n))
             (factor (Math.exp re)))
         (make-rectangular (* factor (cos im))
                           (* factor (sin im))))
       (Math.exp n)))

;; -----------------------------------------------------------------------------
(define (modulo a b)
  "(modulo a b)

   Returns modulo operation on its argumennts."
  (typecheck "modulo" a "number" 1)
  (typecheck "modulo" b "number" 2)
  (- a (* b (floor (/ a b)))))
;; -----------------------------------------------------------------------------
(define (remainder__ a b)
  "(modulo a b)

   Returns remainder from division operation."
  (typecheck "remainder" a "number" 1)
  (typecheck "remainder" b "number" 2)
  (- a (* b (truncate (/ a b)))))

;; -----------------------------------------------------------------------------
(define (list-tail l k)
  "(list-tail list k)

   Returns the sublist of list obtained by omitting the first k elements."
  (typecheck "list-tail" l '("pair" "nil"))
  (if (< k 0)
      (throw (new Error "list-ref: index out of range"))
      (let ((l l) (k k))
        (while (> k 0)
          (if (null? l)
              (throw (new Error "list-tail: not enough elements in the list")))
          (set! l (cdr l))
          (set! k (- k 1)))
        l)))

;; -----------------------------------------------------------------------------
(define (list-ref l k)
  "(list-ref list n)

   Returns n-th element of a list."
  (let ((l (%nth-pair "list-ref" l k)))
    (if (null? l)
        l
        (car l))))

;; -----------------------------------------------------------------------------
(define (not x)
  "(not x)

   Returns true if value is false and false otherwise."
  (if x false true))

;; -----------------------------------------------------------------------------
(define (rationalize number tolerance)
  "(rationalize number tolerance)

   Returns simplest rational number approximation differing from number by no more
   than the tolerance."
  (typecheck "rationalize" number "number" 1)
  (typecheck "rationalize" tolerance "number" 2)
  (lips.rationalize number tolerance))

;; -----------------------------------------------------------------------------
(define (%mem/search access op obj list)
  "(%member obj list function)

   Helper method to get first list where car equal to obj
   using provided function as comparator."
  (if (null? list)
      false
      (if (op (access list) obj)
          list
          (%mem/search access op obj (cdr list)))))

;; -----------------------------------------------------------------------------
(define (memq obj list)
  "(memq obj list)

   Returns first object in the list that match using eq? function."
  (typecheck "memq" list '("nil" "pair"))
  (%mem/search car eq? obj list ))

;; -----------------------------------------------------------------------------
(define (memv obj list)
  "(memv obj list)

   Returns first object in the list that match using eqv? function."
  (typecheck "memv" list '("nil" "pair"))
  (%mem/search car eqv? obj list))

;; -----------------------------------------------------------------------------
(define (member obj list)
  "(member obj list)

   Returns first object in the list that match using equal? function."
  (typecheck "member" list '("nil" "pair"))
  (%mem/search car equal? obj list))

;; -----------------------------------------------------------------------------
(define (%assoc/accessor name)
  "(%assoc/accessor name)

   Returns carr with typecheck using give name."
  (lambda (x)
    (typecheck name x "pair")
    (caar x)))

;; -----------------------------------------------------------------------------
(define (%assoc/search op obj alist)
  "(%assoc/search op obj alist)

   Generic function that used in assoc functions with defined comparator
   function."
  (typecheck "assoc" alist (vector "nil" "pair"))
  (let ((ret (%mem/search (%assoc/accessor "assoc") op obj alist)))
    (if ret
        (car ret)
        ret)))

;; -----------------------------------------------------------------------------
(define assoc (%doc
               "(assoc obj alist)

                Returns pair from alist that match given key using equal? check."
               (curry %assoc/search equal?)))

;; -----------------------------------------------------------------------------
(define assq (%doc
              "(assq obj alist)

               Returns pair from a list that matches given key using eq? check."
              (curry %assoc/search eq?)))

;; -----------------------------------------------------------------------------
(define assv (%doc
              "(assv obj alist)

               Returns pair from alist that match given key using eqv? check."
              (curry %assoc/search eqv?)))

;; -----------------------------------------------------------------------------
;; STRING FUNCTIONS
;; -----------------------------------------------------------------------------
;; (let ((x (make-string 20)))
;;   (string-fill! x #\b)
;;   x)
;; -----------------------------------------------------------------------------
(define (make-string k . rest)
  "(make-string k [char])

   Returns new string with k elements. If char is provided
   it's filled with that character."
  (let ((char (if (null? rest) #\space (car rest))))
    (typecheck "make-string" k "number" 1)
    (typecheck "make-string" char "character" 2)
    (let iter ((result '()) (k k))
      (if (<= k 0)
          (list->string result)
          (iter (cons char result) (- k 1))))))

;; -----------------------------------------------------------------------------
(define (string . args)
  "(string chr1 chr2 ...)

   Function that creates a new string from it's arguments. Each argument
   needs to be a character object."
  (for-each (lambda (x)
              (typecheck "string" x "character"))
            args)
  (list->string args))

;; -----------------------------------------------------------------------------
(define (string-copy string)
  "(string-copy string)

   Returns a copy of the given string."
  (typecheck "string-copy" string "string")
  (--> string (clone)))

;; -----------------------------------------------------------------------------
;;(let ((x "xxxxxxxxxx"))
;;   (string-fill! x #\b)
;;    x)
;; -----------------------------------------------------------------------------
(define (string-fill! string char)
  "(string-fill! symbol char)

   Function that destructively fills the string with given character."
  (typecheck "string-fill!" string "string" 1)
  (typecheck "string-fill!" char "character" 2)
  (string.fill char))

;; -----------------------------------------------------------------------------
(define (identity n)
  "(identity n)

   No-op function. It just returns its argument."
  n)

;; -----------------------------------------------------------------------------
(define (string-copy x)
  "(string-copy x)

   Creates a new string based on given argument."
  (typecheck "string-copy" x "string")
  (lips.LString x))

;; -----------------------------------------------------------------------------
(define (list->string _list)
  "(list->string _list)

   Returns a string from a list of characters."
  (let ((array (list->array
                (map (lambda (x)
                       (typecheck "list->string" x "character")
                       (x.valueOf))
                     _list))))
    (--> array (join ""))))

;; -----------------------------------------------------------------------------
(define (string->list string)
  "(string->list string)

   Returns a list of characters created from string."
  (typecheck "string->list" string "string")
  (array->list (--> (Array.from string)
                    (map (lambda (x)
                           (lips.LCharacter x))))))

;; -----------------------------------------------------------------------------
(define-macro (string-set! object index char)
  "(string-set! string index char)

   Replaces character in string at a given index."
  (let ((input (gensym "input")))
    `(begin
       (let ((,input ,object))
         (typecheck "string-set!" ,input "string")
         (typecheck "string-set!" ,index "number")
         (typecheck "string-set!" ,char "character")
         (try
          (--> ,input (set ,index  ,char))
          (catch (e)
                 (error "string-set!: attempt to change an immutable string")))))))

;; -----------------------------------------------------------------------------
(define (string-length string)
  "(string-length string)

   Returns the length of the string."
  (typecheck "string-length" string "string")
  (. string 'length))

;; -----------------------------------------------------------------------------
(define (string-ref string k)
  "(string-ref string k)

   Returns character inside string at given zero-based index."
  (typecheck "string-ref" string "string" 1)
  (typecheck "string-ref" k "number" 2)
  (lips.LCharacter (string.get k)))

(define (%string-cmp name string1 string2)
  "(%string-cmp name a b)

   Function that compares two strings and returns 0 if they are equal,
   -1 if it is smaller and 1 if is larger. The function compares
   the codepoints of the character."
  (typecheck name string1 "string" 1)
  (typecheck name string2 "string" 2)
  (--> string1 (cmp string2)))

;; -----------------------------------------------------------------------------
(define (string=? string1 string2)
  "(string=? string1 string2)

   Checks if two strings are equal."
  (= (%string-cmp "string=?" string1 string2) 0))

;; -----------------------------------------------------------------------------
(define (string<? string1 string2)
  "(string<? string1 string2)

   Returns true if the second string is smaller than the first one."
  (= (%string-cmp "string<?" string1 string2) -1))

;; -----------------------------------------------------------------------------
(define (string>? string1 string2)
  "(string<? string1 string2)

   Returns true if the second string is larger than the first one."
  (= (%string-cmp "string>?" string1 string2) 1))

;; -----------------------------------------------------------------------------
(define (string<=? string1 string2)
  "(string<? string1 string2)

   Returns true if the second string is not larger than the first one."
  (< (%string-cmp "string<=?" string1 string2) 1))

;; -----------------------------------------------------------------------------
(define (string>=? string1 string2)
  "(string<? string1 string2)

   Returns true if second character is not smaller then the first one."
  (> (%string-cmp "string>=?" string1 string2) -1))

;; -----------------------------------------------------------------------------
(define (%string-ci-cmp name string1 string2)
  "(%string-ci-cmp name a b)

   Function that compares two strings ignoring case and returns 0 if they are equal,
   -1 if it is smaller and 1 if is larger. The function compares
   the codepoints of the character."
  (typecheck name string1 "string" 1)
  (typecheck name string2 "string" 2)
  (--> string1 (lower) (cmp (--> string2 (lower)))))

;; -----------------------------------------------------------------------------
(define (string-ci=? string1 string2)
  "(string-ci=? string1 string2)

   Checks if two strings are equal, ignoring case."
  (= (%string-ci-cmp "string-ci=?" string1 string2) 0))

;; -----------------------------------------------------------------------------
(define (string-ci<? string1 string2)
  "(string-ci<? string1 string2)

   Returns true if the second string is smaller than the first one, ignoring case."
  (= (%string-ci-cmp "string-ci<?" string1 string2) -1))

;; -----------------------------------------------------------------------------
(define (string-ci>? string1 string2)
  "(string-ci<? string1 string2)

   Returns true if the second string is larger than the first one, ignoring case."
  (= (%string-ci-cmp "string-ci>?" string1 string2) 1))

;; -----------------------------------------------------------------------------
(define (string-ci<=? string1 string2)
  "(string-ci<? string1 string2)

   Returns true if the second string is not larger than the first one, ignoring case."
  (< (%string-ci-cmp "string-ci<=?" string1 string2) 1))

;; -----------------------------------------------------------------------------
(define (string-ci>=? string1 string2)
  "(string-ci>=? string1 string2)

   Returns true if second character is not smaller than the first one, ignoring case."
  (> (%string-ci-cmp "string-ci>=?" string1 string2) -1))

;; -----------------------------------------------------------------------------
;; CHARACTER FUNCTIONS
;; -----------------------------------------------------------------------------

;; (display (list->string (list #\A (integer->char 10) #\B)))
;; -----------------------------------------------------------------------------
(define char? (%doc
        "(char? obj)

         Checks if the object is a character."
        (curry instanceof lips.LCharacter)))

;; -----------------------------------------------------------------------------
(define (char->integer chr)
  "(char->integer chr)

   Returns the codepoint of Unicode character."
  (typecheck "char->integer" chr "character")
  (--> chr.__char__ (codePointAt 0)))

;; -----------------------------------------------------------------------------
(define (integer->char n)
  "(integer->char chr)

   Function that converts number argument to character."
  (typecheck "integer->char" n "number")
  (if (integer? n)
      (string-ref (String.fromCodePoint n) 0)
      (throw "argument to integer->char need to be integer.")))

;; -----------------------------------------------------------------------------
(define-macro (%define-chr-re spec str re)
  "(%define-chr-re (name chr) string re)

   Macro defines the procedure that tests character against regular expression."
  `(define ,spec
     ,str
     (typecheck ,(symbol->string (car spec)) ,(cadr spec) "character")
     (not (null? (--> chr (toString) (match ,re))))))

;; -----------------------------------------------------------------------------
(%define-chr-re (char-whitespace? chr)
  "(char-whitespace? chr)

   Returns true if character is whitespace."
  (let-env (interaction-environment)
           (--> **internal-env** (get 'space-unicode-regex))))

;; -----------------------------------------------------------------------------
(%define-chr-re (char-numeric? chr)
  "(char-numeric? chr)

   Returns true if character is number."
  (let-env (interaction-environment)
           (--> **internal-env** (get 'numeral-unicode-regex))))

;; -----------------------------------------------------------------------------
(%define-chr-re (char-alphabetic? chr)
  "(char-alphabetic? chr)

   Returns true if character is leter of the ASCII alphabet."
  (let-env (interaction-environment)
           (--> **internal-env** (get 'letter-unicode-regex))))

;; -----------------------------------------------------------------------------
(define (%char-cmp name chr1 chr2)
  "(%char-cmp name a b)

   Function that compares two characters and return 0 if they are equal,
   -1 second is smaller and 1 if is larger. The function compare
   the codepoints of the character."
  (typecheck name chr1 "character" 1)
  (typecheck name chr2 "character" 2)
  (let ((a (char->integer chr1))
        (b (char->integer chr2)))
    (cond ((= a b) 0)
          ((< a b) -1)
          (else 1))))

;; -----------------------------------------------------------------------------
(define (char=? chr1 chr2)
  "(char=? chr1 chr2)

   Checks if two characters are equal."
  (= (%char-cmp "char=?" chr1 chr2) 0))

;; -----------------------------------------------------------------------------
(define (char<? chr1 chr2)
  "(char<? chr1 chr2)

   Returns true if second character is smaller then the first one."
  (= (%char-cmp "char<?" chr1 chr2) -1))

;; -----------------------------------------------------------------------------
(define (char>? chr1 chr2)
  "(char<? chr1 chr2)

   Returns true if second character is larger then the first one."
  (= (%char-cmp "char>?" chr1 chr2) 1))

;; -----------------------------------------------------------------------------
(define (char<=? chr1 chr2)
  "(char<? chr1 chr2)

   Returns true if second character is not larger then the first one."
  (< (%char-cmp "char<=?" chr1 chr2) 1))

;; -----------------------------------------------------------------------------
(define (char>=? chr1 chr2)
  "(char<? chr1 chr2)

   Returns true if second character is not smaller then the first one."
  (> (%char-cmp "char>=?" chr1 chr2) -1))

;; -----------------------------------------------------------------------------
(define (%char-ci-cmp name chr1 chr2)
  "(%char-cmp name a b)

   Function that compares two characters and return 0 if they are equal,
   -1 second is smaller and 1 if is larger. The function compare
   the codepoints of the character."
  (typecheck name chr1 "character" 1)
  (typecheck name chr2 "character" 2)
  (%char-cmp name (char-downcase chr1) (char-downcase chr2)))

;; -----------------------------------------------------------------------------
(define (char-ci=? chr1 chr2)
  "(char-ci=? chr1 chr2)

   Checks if two characters are equal."
  (= (%char-ci-cmp "char-ci=?" chr1 chr2) 0))

;; -----------------------------------------------------------------------------
(define (char-ci<? chr1 chr2)
  "(char-ci<? chr1 chr2)

   Returns true if second character is smaller then the first one."
  (= (%char-ci-cmp "char-ci<?" chr1 chr2) -1))

;; -----------------------------------------------------------------------------
(define (char-ci>? chr1 chr2)
  "(char-ci<? chr1 chr2)

   Returns true if second character is larger then the first one."
  (= (%char-ci-cmp "char-ci>?" chr1 chr2) 1))

;; -----------------------------------------------------------------------------
(define (char-ci<=? chr1 chr2)
  "(char-ci<? chr1 chr2)

   Returns true if second character is not larger then the first one."
  (< (%char-ci-cmp "char-ci<=?" chr1 chr2) 1))

;; -----------------------------------------------------------------------------
(define (char-ci>=? chr1 chr2)
  "(char-ci<? chr1 chr2)

   Returns true if second character is not smaller then the first one."
  (> (%char-ci-cmp "char-ci>=?" chr1 chr2) -1))

;; -----------------------------------------------------------------------------
(define (char-upcase char)
  "(char-upcase char)

   Create uppercase version of the character."
  (typecheck "char-upcase" char "character")
  (char.toUpperCase))

;; -----------------------------------------------------------------------------
(define (char-downcase char)
  "(char-downcase chr)

   Create lowercase version of the character."
  (typecheck "char-upcase" char "character")
  (char.toLowerCase))

;; -----------------------------------------------------------------------------
(define (char-upper-case? char)
  "(char-upper-case? char)

   Checks if character is upper case."
  (typecheck "char-upper-case?" char "character")
  (and (char-alphabetic? char)
       (char=? (char-upcase char) char)))

;; -----------------------------------------------------------------------------
(define (char-lower-case? char)
  "(char-upper-case? char)

   Checks if character is lower case."
  (typecheck "char-lower-case?" char "character")
  (and (char-alphabetic? char)
       (char=? (char-downcase char) char)))

;; -----------------------------------------------------------------------------
(define (write obj . rest)
  "(write obj [port])

   Write object to standard output or give port. For strings it will include
   wrap in quotes."
  (let ((port (if (null? rest) (current-output-port) (car rest))))
    (if (binary-port? port)
        (display obj port)
        (display (repr obj true) port))))

;; -----------------------------------------------------------------------------
(define (write-char char . rest)
  "(write-char char [port])

   Write single character to given port using write function."
  (typecheck "write-char" char "character")
  (if (not (null? rest))
      (typecheck "write-char" (car rest) "output-port"))
  (apply display (cons (char.valueOf) rest)))

;; -----------------------------------------------------------------------------
(define fold-right reduce)
(define fold-left fold)

;; -----------------------------------------------------------------------------
(define (make-vector n . rest)
  "(make-vector n [fill])

   Creates a new vector with n empty elements. If fill is specified it will set
   all elements of the vector to that value."
  (let ((result (new Array n)))
    (if (not (null? rest))
        (--> result (fill (car rest)))
        result)))

;; -----------------------------------------------------------------------------
(define (vector? n)
  "(vector? n)

   Returns true if value is vector and false if not."
  (string=? (type n) "array"))

;; -----------------------------------------------------------------------------
(define (vector-ref vec n)
  "(vector-ref vec n)

   Returns nth element of the vector vec."
  (typecheck "vector-ref" vec "array" 1)
  (typecheck "vector-ref" n "number" 2)
  (. vec n))

;; -----------------------------------------------------------------------------
(define (vector-set! vec n value)
  "(vector-set! vec n value)

   Function that sets nth item of the vector to value."
  (typecheck "vector-ref" vec "array" 1)
  (typecheck "vector-ref" n "number" 2)
  (set-obj! vec n value))

;; -----------------------------------------------------------------------------
(define (vector-fill! vec value)
  "(vector-fill! vec value)

   Set every element of the vector to given value."
  (typecheck "vector-ref" vec "array")
  (let recur ((n (- (length vec) 1)))
    (if (>= n 0)
        (begin
          (set-obj! vec n value)
          (recur (- n 1))))))

;; -----------------------------------------------------------------------------
(define (vector-length vec)
  "(vector-length vec)

   Returns length of the vector. It errors if the argument is not a vector."
  (typecheck "vector-length" vec "array")
  (length vec))

;; -----------------------------------------------------------------------------
;; case macro from R7RS spec https://small.r7rs.org/wiki/R7RSSmallErrata/
;; -----------------------------------------------------------------------------
(define-syntax case
  (syntax-rules (else =>)
    ((case (key ...)
       clauses ...)
     (let ((atom-key (key ...)))
       (case atom-key clauses ...)))
    ((case key
       (else => result))
     (result key))
    ((case key
       (else result1 result2 ...))
     (begin result1 result2 ...))
    ((case key
       ((atoms ...) => result))
     (if (memv key '(atoms ...))
         (result key)))
    ((case key
       ((atoms ...) => result)
       clause clauses ...)
     (if (memv key '(atoms ...))
         (result key)
         (case key clause clauses ...)))
    ((case key
       ((atoms ...) result1 result2 ...))
     (if (memv key '(atoms ...))
         (begin result1 result2 ...)))
    ((case key
       ((atoms ...) result1 result2 ...)
       clause clauses ...)
     (if (memv key '(atoms ...))
         (begin result1 result2 ...)
         (case key clause clauses ...))))
  "(case value
        ((<items>) result1)
        ((<items>) result2)
        [else result3])

   Macro for switch case statement. It test if value is any of the item. If
   item match the value it will return corresponding result expression value.
   If no value match and there is else it will return that result.")

;; -----------------------------------------------------------------------------
(--> lips.Formatter.defaults.exceptions.specials (push "case")) ;; 2 indent

;; -----------------------------------------------------------------------------
(define (numerator n)
  "(numerator n)

   Return numerator of rational or same number if n is not rational."
  (typecheck "numerator" n "number")
  (cond ((integer? n) n)
        ((rational? n) n.__num__)
        (else
         (numerator (inexact->exact n)))))

;; -----------------------------------------------------------------------------
(define (denominator n)
  "(denominator n)

   Return denominator of rational or same number if one is not rational."
  (typecheck "denominator" n "number")
  (cond ((integer? n) n)
        ((rational? n) n.__denom__)
        ((exact? n) 1)
        (else
         (denominator (inexact->exact n)))))

;; -----------------------------------------------------------------------------
(define (imag-part n)
  "(imag-part n)

   Return imaginary part of the complex number n."
  (typecheck "imag-part" n "number")
  (if (%number-type "complex" n)
      n.__im__
      0))

;; -----------------------------------------------------------------------------
(define (real-part n)
  "(real-part n)

   Return real part of the complex number n."
  (typecheck "real-part" n "number")
  (if (%number-type "complex" n)
      n.__re__
      n))

;; -----------------------------------------------------------------------------
(define (make-polar r angle)
  "(make-polar magnitude angle)

   Create new complex number from polar parameters."
  (typecheck "make-polar" r "number")
  (typecheck "make-polar" angle "number")
  (if (or (complex? r) (complex? angle))
      (error "make-polar: argument can't be complex")
      (let ((re (* r (sin angle)))
            (im (* r (cos angle))))
        (make-rectangular im re))))

;; -----------------------------------------------------------------------------
(define (angle x)
  "(angle x)

   Returns angle of the complex number in polar coordinate system."
  ;; TODO: replace %number-type with typechecking
  (if (not (%number-type "complex" x))
      (error "angle: number need to be complex")
      (Math.atan2 x.__im__ x.__re__)))

;; -----------------------------------------------------------------------------
(define (magnitude x)
  "(magnitude x)

   Returns magnitude of the complex number in polar coordinate system."
  (if (not (%number-type "complex" x))
      (error "magnitude: number need to be complex")
      (sqrt (+ (* x.__im__ x.__im__) (* x.__re__ x.__re__)))))

;; -----------------------------------------------------------------------------
;; ref: https://stackoverflow.com/a/14675103/387194
;; -----------------------------------------------------------------------------
(define random
  (let ((a 69069) (c 1) (m (expt 2 32)) (seed 19380110))
    (lambda new-seed
      "(random)
       (random seed)

       Function that generates new random real number using Knuth algorithm."
      (if (pair? new-seed)
          (set! seed (car new-seed))
          (set! seed (modulo (+ (* seed a) c) m)))
      (exact->inexact (/ seed m)))))

;; -----------------------------------------------------------------------------
(define (eof-object? obj)
  "(eof-object? arg)

   Checks if value is eof object, returned from input string
   port when there are no more data to read."
  (eq? obj eof))

;; -----------------------------------------------------------------------------
(define (output-port? obj)
  "(output-port? arg)

   Returns true if argument is output port."
  (instanceof lips.OutputPort obj))

;; -----------------------------------------------------------------------------
(define (input-port? obj)
  "(input-port? arg)

   Returns true if argument is input port."
  (instanceof lips.InputPort obj))

;; -----------------------------------------------------------------------------
(define (char-ready? . rest)
  "(char-ready?)
   (char-ready? port)

   Checks if characters is ready in input port. This is useful mostly
   for interactive ports that return false if it would wait for user input.
   It return false if port is closed."
  (let ((port (if (null? rest) (current-input-port) (car rest))))
    (typecheck "char-ready?" port "input-port")
    (port.char_ready)))

;; -----------------------------------------------------------------------------
(define open-input-file
  (let ((readFile #f))
    (lambda(filename)
      "(open-input-file filename)

       Returns new Input Port with given filename. In Browser user need to
       provide global fs variable that is instance of FS interface."
      (new lips.InputFilePort (%read-file false filename) filename))))

;; -----------------------------------------------------------------------------
(define (close-input-port port)
  "(close-input-port port)

   Procedure close port that was opened with open-input-file. After that
   it no longer accept reading from that port."
  (typecheck "close-input-port" port "input-port")
  (port.close))

;; -----------------------------------------------------------------------------
(define (close-output-port port)
  "(close-output-port port)

   Procedure close port that was opened with open-output-file. After that
   it no longer accept write to that port."
  (typecheck "close-output-port" port "output-port")
  (port.close))

;; -----------------------------------------------------------------------------
(define (call-with-input-file filename proc)
  "(call-with-input-file filename proc)

   Procedure open file for reading, call user defined procedure with given port
   and then close the port. It return value that was returned by user proc
   and it close the port even if user proc throw exception."
  (let ((p (open-input-file filename)))
    (try (proc p)
         (finally
          (close-input-port p)))))

;; -----------------------------------------------------------------------------
(define (call-with-output-file filename proc)
  "(call-with-output-file filename proc)

   Procedure open file for writing, call user defined procedure with port
   and then close the port. It return value that was returned by user proc
   and it close the port even if user proc throw exception."
  (let ((p (open-output-file filename)))
    (try (proc p)
         (finally
          (close-output-port p)))))

;; -----------------------------------------------------------------------------
(define (with-input-from-port port thunk)
  "(with-input-from-port port thunk)

   Procedure use port and make it current-input-port then thunk is executed.
   After thunk is executed current-input-port is restored and given port
   is closed."
  (let* ((env **interaction-environment**)
         (internal-env (env.get '**internal-env**))
         (old-stdin (internal-env.get "stdin")))
    (internal-env.set "stdin" port)
    (try
     (thunk)
     (finally
      (internal-env.set "stdin" old-stdin)
      (close-input-port port)))))

;; -----------------------------------------------------------------------------
(define (with-input-from-file string thunk)
  "(with-input-from-file string thunk)

   Procedure open file and make it current-input-port then thunk is executed.
   After thunk is executed current-input-port is restored and file port
   is closed."
  (with-input-from-port (open-input-file string) thunk))

;; -----------------------------------------------------------------------------
(define (with-input-from-string string thunk)
  "(with-input-from-string string thunk)

   Procedure open string and make it current-input-port then thunk is executed.
   After thunk is executed current-input-port is restored and string port
   is closed."
  (with-input-from-port (open-input-string string) thunk))

;; -----------------------------------------------------------------------------
(define (with-output-to-file string thunk)
  (let* ((port (open-output-file string))
         (env **interaction-environment**)
         (internal-env (env.get '**internal-env**))
         (old-stdout (internal-env.get "stdout")))
    (internal-env.set "stdout" port)
    (try
     (thunk)
     (finally
      (internal-env.set "stdout" old-stdout)
      (close-output-port port)))))

;; -----------------------------------------------------------------------------
(define (file-exists? filename)
  (new Promise (lambda (resolve)
                 (let ((fs (--> lips.env (get '**internal-env**) (get 'fs))))
                   (if (null? fs)
                       (throw (new Error "file-exists?: fs not defined"))
                       (fs.stat filename (lambda (err stat)
                                           (if (null? err)
                                               (resolve (stat.isFile))
                                               (resolve #f)))))))))



;; -----------------------------------------------------------------------------
(define open-output-file
  (let ((open))
    (lambda (filename)
      "(open-output-file filename)

       Function that opens file and return port that can be used for writing. If file
       exists it will throw an Error."
      (typecheck "open-output-file" filename "string")
      (if (not (procedure? open))
          (set! open (%fs-promisify-proc 'open "open-output-file")))
      (if (file-exists? filename)
          (throw (new Error "open-output-file: file exists"))
          (lips.OutputFilePort filename (open filename "w"))))))

;; -----------------------------------------------------------------------------
(define (scheme-report-environment version)
  "(scheme-report-environment version)

   Returns new Environment object for given Scheme Spec version.
   Only argument 5 is supported that create environment for R5RS."
  (typecheck "scheme-report-environment" version "number")
  (case version
    ((5) (%make-env "R5RS" * + - / < <= = > >= abs acos and angle append apply asin assoc assq assv
                    atan begin boolean? caaaar caaadr caaar caadar caaddr caadr caar cadaar cadadr
                    cadar caddar cadddr caddr cadr call-with-current-continuation call-with-input-file
                    call-with-output-file call-with-values car case cdaaar cdaadr cdaar cdadar cdaddr
                    cdadr cdar cddaar cddadr cddar cdddar cddddr cdddr cddr cdr ceiling char->integer
                    char-alphabetic? char-ci<=? char-ci<? char-ci=? char-ci>=? char-ci>? char-downcase
                    char-lower-case? char-numeric?  char-ready?  char-upcase char-upper-case?
                    char-whitespace? char<=? char<? char=? char>=? char>? char? close-input-port
                    close-output-port complex? cond cons cos current-input-port current-output-port
                    define define-syntax delay denominator display do dynamic-wind eof-object? eq?
                    equal? eqv? eval even? exact->inexact exact? exp expt floor for-each force gcd
                    if imag-part inexact->exact inexact? input-port? integer->char integer?
                    interaction-environment lambda lcm length let let* let-syntax letrec letrec-syntax
                    list list->string list->vector list-ref list-tail list? load log magnitude
                    make-polar make-rectangular make-string make-vector map max member memq memv min
                    modulo negative? newline not null-environment null? number->string number?
                    numerator odd? open-input-file open-output-file or output-port? pair? peek-char
                    positive? procedure? quasiquote quote quotient rational? rationalize read read-char
                    real-part real? remainder reverse round scheme-report-environment set! set-car!
                    set-cdr! sin sqrt string string->list string->number string->symbol string-append
                    string-ci<=? string-ci<? string-ci=? string-ci>=? string-ci>? string-copy
                    string-fill! string-length string-ref string-set! string<=? string<? string=?
                    string>=? string>? string? substring symbol->string symbol? tan truncate values
                    vector vector->list vector-fill! vector-length vector-ref vector-set! vector?
                    with-input-from-file with-output-to-file write write-char zero?))
    ((7) (%make-env "R7RS" - * / _ + < <= = => > >= abs acos and angle append apply asin assoc assq
                    assv atan begin binary-port? boolean? boolean=? bytevector bytevector?  bytevector-append
                    bytevector-copy bytevector-copy!  bytevector-length bytevector-u8-ref bytevector-u8-set!  caaaar
                    caaadr caaar caadar caaddr caadr caar cadaar cadadr cadar caddar cadddr caddr cadr call/cc
                    call-with-current-continuation call-with-input-file call-with-output-file call-with-port
                    call-with-values car case case-lambda cdaaar cdaadr cdaar cdadar cdaddr cdadr cdar cddaar cddadr
                    cddar cdddar cddddr cdddr cddr cdr ceiling char? char<? char<=? char=? char>? char>=?
                    char->integer char-alphabetic? char-ci<? char-ci<=? char-ci=? char-ci>? char-ci>=?
                    char-downcase char-foldcase char-lower-case? char-numeric? char-ready? char-upcase
                    char-upper-case? char-whitespace? close-input-port close-output-port close-port command-line
                    complex? cond cond-expand cons cos current-error-port current-input-port current-jiffy
                    current-output-port current-second define define-record-type define-syntax define-values delay
                    delay-force delete-file denominator digit-value display do dynamic-wind else emergency-exit
                    environment eof-object eof-object? eq? equal? eqv? error error-object? error-object-irritants
                    error-object-message eval even? exact exact? exact-integer? exact-integer-sqrt exit exp expt
                    features file-exists? finite? floor floor/ floor-quotient floor-remainder flush-output-port force
                    for-each gcd get-environment-variable get-environment-variables get-output-bytevector
                    get-output-string guard if imag-part import include include-ci inexact inexact? infinite?
                    input-port? input-port-open? integer? integer->char interaction-environment
                    interaction-environment jiffies-per-second lambda lcm length let let* let*-values letrec letrec*
                    letrec-syntax let-syntax let-values list list? list->string list->vector list-copy list-ref
                    list-set! list-tail load log magnitude make-bytevector make-list make-parameter make-polar
                    make-promise make-rectangular make-string make-vector map max member memq memv min modulo nan?
                    negative? newline not null? number? number->string numerator odd? open-binary-input-file
                    open-binary-output-file open-input-bytevector open-input-file open-input-string
                    open-output-bytevector open-output-file open-output-string or output-port? output-port-open? pair?
                    parameterize peek-char peek-u8 port? positive? procedure? quasiquote quote quotient raise
                    raise-continuable rational? rationalize read read-bytevector read-bytevector! read-char read-line
                    read-string read-u8 real? real-part remainder reverse round scheme-report-environment set!
                    set-car! set-cdr! sin sqrt square string string? string<? string<=? string=? string>?
                    string>=? string->list string->number string->symbol string->utf8 string->vector string-append
                    string-ci<? string-ci<=? string-ci=? string-ci>? string-ci>=? string-copy string-copy!
                    string-downcase string-fill! string-foldcase string-for-each string-length string-map string-ref
                    string-set! string-upcase substring symbol? symbol=? symbol->string syntax-error syntax-rules tan
                    textual-port? truncate truncate/ truncate-quotient truncate-remainder u8-ready? unless unquote
                    unquote-splicing utf8->string values vector vector? vector->list vector->string vector-append
                    vector-copy vector-copy! vector-fill! vector-for-each vector-length vector-map vector-ref
                    vector-set! when with-exception-handler with-input-from-file with-output-to-file write
                    write-bytevector write-char write-shared write-simple write-string write-u8 zero?))
    (else (throw (new Error (string-append "scheme-report-environment: version "
                                           (number->string version)
                                           " not supported"))))))
