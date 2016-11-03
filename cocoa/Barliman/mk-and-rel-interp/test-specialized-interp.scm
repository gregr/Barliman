(load "mk/mk-vicare.scm")
(load "mk/mk.scm")
(load "mk/test-check.scm")

(set! allow-incomplete-search? #t)
(set! enable-conde1? #t)

(define closure-tag (gensym "#%closure"))
(define prim-tag (gensym "#%primitive"))

(define empty-env '())

;; TODO: specialized synthesis relational interpreter
;; specialized goal scheduling and eval continuation management
;; goal graph
;;   dependency ordered goal DAGs
;;     generate guesses for children first, whose results parents depend on
;;     generate guesses for most constrained/concrete goals first
;;       how is this measured and compared?
;;         maybe just consider topmost/head demanded terms for every demand path?
;;           propagate demand upward
;;             from results to terms, to results those terms require, etc.
;;           first satisfy each head independently
;;             to avoid wasting time in unsatisfiable problems
;;           then we can consider/generate heads in any order, updating as we go?
;;             need to re-evaluate/satisfy heads as constraints are added
;;             unbound logic variable listener map
;;               unbound variables -> affected goals
;;                 re-consider goals upon binding/constraining
;;     track relevance (terms are relevant if their results are demanded)
;;       procedure body that doesn't use an arg; only need to satisfy arg termination
;;       potentially 'satisfy-only' goals are put aside until demanded
;;         put aside with a satisfaction example in case it's difficult to compute?
;;           e.g., may be difficult to produce an 'absento' user gensym or shadowed prim
;;             note: need inductive proofs to terminate some unsatisfiable problems
;;               e.g., (car (cons A B)) and (cdr (cons A B)) are useless to generate
;;                 Say we're performing (eval-expo T env x).  We need to generate T to
;;                 produce x, given env.  If nothing in the env is exactly x, then we
;;                 try to build an x using primitives:
;;                   null?, pair?, symbol?, not: if x is a boolean
;;                   cons: if the x is a pair
;;                   car, or cdr otherwise; this is the interesting case.
;;                 Say that car/cdr are all that's left; let's follow car for simplicity.
;;                 So now we need to:
;;                   T=(car ,U), so (eval-expo `(car ,U) env x)
;;                   which implies (eval-expo U env `(,x . _))
;;                 If there is a (,x . _) available in env, we're done.  Otherwise, we
;;                 only continue trying car and cdr.  Why not the others?  Other than
;;                 cons, they produce booleans, and cons can be shown to be useless:
;;                 Say we try:
;;                   U=(cons ,V _), so (eval-expo `(cons ,V _) env `(,x . _))
;;                   which implies (eval-expo V env x).  But we're already trying to
;;                   generate such a V, called T!  There is no solution down this path
;;                   that we won't already find with just car and cdr.  If car and cdr can't
;;                   be used to find the answer, cons would end up searching forever when we
;;                   should instead just terminate.
;;                 Special case: we're solving a weird code as data problem, such as one
;;                 with an external constraint insisting the datum T contain a 'cons' symbol.
;;                 Well, we have to generate a cons to satisfy that external constraint!  But
;;                 in this case, the constraint itself should be usable as a pre-generator,
;;                 freeing us to continue reasoning inductively like this with whatever holes
;;                 remain in the pre-generated skeleton that need to be synthesized.
;;                 Another option for this special case: instead of forcing cons to terminate,
;;                 suspend it until car/cdr uses are exhausted.  If there are car/cdr solutions,
;;                 but they fail due to such a weird constraint, resuming the cons branch may
;;                 succeed.  This is probably a safer choice for completeness.
;; grammar-based term recognizers and generators
;;   small, composable pieces to allow problems to be broken up and refined
;;   specialized unify/disunify predicates tied to boolean outcomes
;;     distinguish between test and assign
;;   term generators may use (env -> result) component to improve guesses
;;     e.g., `if` might partition results and satisfy partitions independently
;;     e.g., inductive proofs for terminating unsatisfiable problems
;; size incrementing generation
;; unshadowed environment enumeration
;; space and time quotas for evaluation slices
;; JIT denotational interpretation
;;   must continue to respect quotas
;;   escape when analysis is required (e.g., running into an unbound term)
;; strategic, benign incompleteness
;;   weighted or DFS disjunctions
;;   avoid redundant terms
;;     if both 'cons' and 'list' are available, usually no need to apply 'list'?
;;       but it may make sense to pass list as an argument
;;       and 'list' terms may be smaller and faster to find...
;;   limit generation of if/cond/match (can also do everything with just 'if')
;;   prefer applying primitives that produce booleans in conditional positions
;;   possibly omit applications of literal lambdas
;;   synthesize letrec rather than begin/define; can translate for the UI

;; values are recognized and generated by constraints, which are introduced by:
;;   grammars
;;     term syntax: full or fragments (e.g., symbol heads, param lists)
;;     environments
;;     applicables: closures, primitives, and their components
;;     general s-exprs/transparents
;;   parsing, computation
;;   external forces
;; what is demand?
;;   we'd like to solve first for values whose constraints are harder to satisfy
;;   demand is a heuristic indicating a transitive, difficult constraint
;;   it originates by crawling the top-level result, then propagates via:
;;     parsing
;;       syntax of terms evaluating to demanded values is demanded
;;     computation
;;       demanded variable references demand the corresponding env value
;;         demanding env values also demands the relevant env structure
;;       the procedure in a demanded procedure application is demanded
;;       demanded conditionals (can be complicated)
;;         the branch indicated by the condition is demanded
;;         so the condition is normally demanded
;;         but if both branches are equal?, the condition is no longer demanded
;;       demanded not, equal?, null?, pair?, symbol?, car, cdr
;;       note: cons facilitiates the flow of demand by connecting values

;; state:
;;   processing ready goals
;;     parse and compute known portions of terms and their evaluations
;;       propagate demand accordingly
;;     portions filled with logic variables will be solved later
;;       create new goals for the logic variables
;;       insert processed and new goals into dependency DAG
;;   pending goals
;;     parsing
;;       (syntax, term) grouped by syntax
;;     evaluation
;;       (term, env, value) grouped by term
;;     goal details
;;       goal-id -> goal-attrs
;;     demanded goals
;;       goals that should be good guessing candidates
;;         dependents are constrained enough to narrow search space
;;   constraint store
;;     logic variable -> constraints/goals
;;       logic variables refer to known or attributes of unknown values
;;         constraints
;;         goals they depend on
;;         goals depending on them

;; variable attributes:
;;   demand status
;;   dependent goals
;;     when new constraints are added for this variable, update these goals
;;   constraints
;;     mk-derived constraints
;;       numbero, symbolo, absento, =/=*
;;     extended constraints
;;       individual =/=
;;         singletons: (), #t, #f,
;;         members of infinite sets: [number], [symbol], [pair], [lvar]
;;       negated type constraints:
;;         not-pair, not-number, not-symbol
;;         be careful about satisfiability:
;;           not-pair, not-number, not-symbol, and =/= for (), #t, and #f gives the empty set
;;       grammars
;;         applicable: prim or closure
;;         not-applicable: quotable
;;         term, and related syntax
;;           operator: term OR syntactic symbol (so it's actually a superset of term)
;;             quote, if, lambda, letrec, begin/define, cond, match, and, or
;;           parameter list:
;;             list of symbols, all different (=/=)
;;         env (with additional env-specific constraints):
;;           in-envo
;;             e.g., this is an unsatisfiable situation:
;;               env binders = {unknown1, unknown2, known...}
;;               term references 3 symbols not bound in 'known' portion
;;             e.g., this can prove non-shadowing of some names
;;               env binders = {unknown1, unknown2, known...}
;;               term references 2 symbols not bound in 'known' portion
;;               full set of bound names is now known
;;             track satisfiability when individual symbol constraints are updated independently
;;               need some kind of (symbol -> env) dependency structure here
;;           not-in-envo: set of symbols (likely special syntax) to avoid binding
;;       future: finite/interval domains, comparison, arithmetic

;; goal types:
;;   term construction
;;     operator: which will determine how to process operands
;;     lambda parameter list
;;     letrec binding(s)
;;     parsing: lambda body, if branches, etc., which may not end up evaluated
;;     other special syntax: begin/define, cond, match
;;   env construction
;;     symbol resolution
;;       links a variable used as an env symbol to its containing env
;;       simplify in-envo/not-in-envo constraints of the containing env
;;   evaluation: a variable may be the term, env, or result
;;     as the result, a variable provides information that flows backwards

;(define-record-type goal-parse (fields term penv))
;(define-record-type goal-parse-operator (fields op penv))
;(define-record-type goal-parse-parameters (fields params penv))
;(define-record-type goal-parse-letrec-bindings (fields bindings penv))
;(define-record-type goal-penv-resolve (fields symbol penv))
;(define-record-type goal-env-resolve (fields symbol env))
(define-record-type goal-eval (fields term env result))

;; TODO: How do we learn about updated =/= vars to identify unsatisfiability?
;; Assign the cx in both directions? (Only needed for singleton assignments.)
;; #f for numbers, symbols, pairs if fully negated

;; negated domains for [un]known types
(define-record-type domain-unknown (fields nil? t? f? number? symbol? pair? applicable?))
;(define-record-type domain-term-=/= (fields nil? t? f? numbers symbols pairs))
;(define-record-type domain-operator-=/= (fields symbols pairs))
;(define-record-type domain-params-=/= (fields symbols symbol-lists))
;(define-record-type domain-env-=/= (fields envs))
;(define-record-type domain-applicable-=/= (fields applicables))
;(define-record-type domain-number-=/= (fields numbers))
;(define-record-type domain-symbol-=/= (fields symbols))
; replace with domain tags for: number, symbol, applicable, env, params, operator

(define-record-type constraints (fields domain vars-=/= absent =/=*))
(define-record-type vattr (fields cxs goal-dependents goal-dependencies))
(define-record-type estate (fields vs goals))

(define domain-empty (make-domain-unknown-=/= #t #t #t '() '() '() '()))
(define constraints-empty (make-constraints domain-empty '() '() '()))
(define vattr-empty (make-vattr constraints-empty '() '()))
(define estate-empty (make-estate empty-subst-map empty-subst-map))

;TODO: ==, =/=, absento, symbolo, numbero, applicableo, not-applicableo, envo, paramso, termo, operatoro, parse-termo, eval-termo
; quotableo === not-applicableo
;
; can we really support negated patterns like (not (? symbol?))? how about (not (? bound?)) instead of using not-bound?
; does each pattern have to explicitly include negations of earlier patterns? hopefully not

; primitives: equal?, symbol?, number?
; syntax: lambda, let, letrec, if, and, or, match, match-dfs, match-ws, match-c, match-cdfs, match-cws, tagged

(let ((closure-tag (gensym "#%closure"))
      (prim-tag (gensym "#%primitive"))
      (empty-env '())
      (initial-env `((cons . (val . (,prim-tag . cons)))
                     (car . (val . (,prim-tag . car)))
                     (cdr . (val . (,prim-tag . cdr)))
                     (null? . (val . (,prim-tag . null?)))
                     (pair? . (val . (,prim-tag . pair?)))
                     (symbol? . (val . (,prim-tag . symbol?)))
                     (not . (val . (,prim-tag . not)))
                     (equal? . (val . (,prim-tag . equal?)))
                     (list . (val . (,closure-tag (lambda x x) ,empty-env)))
                     . ,empty-env)))

(letrec
  ((applicable-tag? (lambda (v)
                      (or (equal? closure-tag v) (equal? prim-tag v))))
   (quotable? (lambda (v)
                (match v
                  ((? symbol?) (not (applicable-tag? v)))
                  (`(,a . ,d) (and (quotable? a) (quotable? d)))
                  (_ #t))))
   (not-in-params? (lambda (ps sym)
                     (match ps
                       ('() #t)
                       (`(,a . ,d)
                         (and (not (equal? a sym)) (not-in-params? d sym))))))
   (param-list? (lambda (x)
                  (match x
                    ('() #t)
                    (`(,(? symbol? a) . ,d)
                      (and (param-list? d) (not-in-params? d a)))
                    (_ #f))))
   (params? (lambda (x)
              (match-ws x
                (10 (? param-list?) #t)
                (1 x (symbol? x)))))
   (in-env? (lambda (env sym)
              (match env
                ('() #f)
                (`(,a . ,d) (or (equal? a sym) (in-env? d sym))))))
   (extend-env* (lambda (params args env)
                  (match `(,params . ,args)
                    (`(() . ()) env)
                    (`((,x . ,dx*) . (,a . ,da*))
                      (extend-env* dx* da* `((,x . (val . ,a)) . ,env))))))
   (lookup (lambda (env sym)
             (match env
               (`((,y . ,b) . ,rest)
                 (if (equal? sym y)
                   (match b
                     (`(val . ,v) v)
                     (`(rec . ,lam-expr) `(,closure-tag ,lam-expr ,env)))
                   (lookup rest sym))))))
   (term?
     (lambda (term env)
       (let ((term1? (lambda (v) (term? v env)))
             (terms? (lambda (ts env)
                       (match ts
                         ('() #t)
                         (`(,t . ,ts) (and (term? t env) (terms? ts env)))))))
         (match term
           (#t #t)
           (#f #t)
           ((? number?) #t)
           ((and (? symbol? sym)) (in-env? env sym))
           (`(,(? term1?) . ,rands) (terms? rands env))
           (`(quote ,datum) (quotable? datum))
           (`(if ,c ,t ,f) (and (term1? c) (term1? t) (term1? f)))
           (`(lambda ,params ,body)
             (and (params? params)
                  (let ((res (match params
                               ((not (? symbol? params))
                                (extend-env* params params env^))
                               (sym `((,x . (val . ,x)) . ,env^)))))
                    (term? body res))))
           (`(letrec ((,p-name (lambda ,params ,body)))
               ,letrec-body)
             (and (params? params)
                  (let ((res `((,p-name . (rec . (lambda ,params ,body)))
                               . ,env)))
                    (and (term? body res) (term? letrec-body res)))))
           (_ #f)))))
   (eval-prim
     (lambda (prim-id args)
       (match `(,prim-id . ,args)
         (`(cons ,a ,d) `(,a . ,d))
         (`(car (,(and (not (? applicable-tag?)) a) . ,d)) a)
         (`(cdr (,(and (not (? applicable-tag?)) a) . ,d)) d)
         (`(null? ,v) (match v ('() #t) (_ #f)))
         (`(pair? ,v) (match v (`(,(not (? applicable-tag?)) . ,_) #t) (_ #f)))
         (`(symbol? ,v) (symbol? v))
         (`(number? ,v) (number? v))
         (`(not ,v) (match v (#f #t) (_ #f)))
         (`(equal? ,v1 ,v2) (equal? v1 v2)))))
   (eval-term-list
     (lambda (terms env)
       (match terms
         ('() '())
         (`(,term . ,terms)
           `(,(eval-term term env) . ,(eval-term-list terms env))))))
   (eval-term
     (lambda (term env)
       (let ((bound? (lambda (sym) (in-env? env sym)))
             (term1? (lambda (v) (term? v env))))
         (tagged `(eval-term ,term ,env)
           (match-cdfs term
             (1 #t #t)
             (1 #f #f)
             (1 (? number? num) num)
             (1 `((and 'quote (not (? bound?))) ,(? quotable? datum)) datum)
             (1 (? symbol? sym) (lookup env sym))
             (1 (and `(,op . ,_) operation)
               (match-cws operation
                 (0 10 `(,(or (? bound?) (not (? symbol?))) . ,rands)
                  (let ((op (eval-term op env))
                        (a* (eval-term-list rands env)))
                    (match-c op
                      (0 `(,prim-tag . ,prim-id) (eval-prim prim-id a*))
                      (0 `(,closure-tag (lambda ,x ,body) ,env^)
                       (let ((res (match-cws x
                                    (0 10 (not (? symbol? params))
                                     (extend-env* params a* env^))
                                    (0 1 sym `((,x . (val . ,a*)) . ,env^)))))
                         (eval-term body res))))))
                 (1 10 `(if ,condition ,alt-true ,alt-false)
                  (if (eval-term condition env)
                    (eval-term alt-true env)
                    (eval-term alt-false env)))
                 (1 1 (? term1? `(lambda ,params ,body))
                  `(,closure-tag (lambda ,params ,body) ,env))
                 (1 1 (? term1? `(letrec ((,p-name (lambda ,params ,body)))
                                   ,letrec-body))
                  (eval-term
                    letrec-body `((,p-name . (rec . (lambda ,params ,body)))
                                  . ,env)))))))))))

  ; TODO: main entry into eval-term ...
  ; start with proper-env check

  )


)


(define (eval-in-envo term env val)
  ;; TODO: start with denvo
  (define (eval-termo term env val)
    (
     (
        (
         )))
    )

  (lambda (mk-st)
    ;; TODO: import mk constraints

    ;; build initial state with initial eval goal ready-demanded
    ;; start processing, splitting states when guessing

    ;; TODO: export mk constraints for each answer state produced
    ))

; deterministic evaluation benchmark ideas to measure sources of overhead
; across programs: append, reverse, map, fold, mini interpreter, remove-foo, etc.
; across program implementations: tailcall, w/ fold, etc.
; across runtimes:
;   scheme, mk-only, mixed
; across interpreter architectures:
;   immediate (scheme only)
;   eval at runtime (scheme only)
;   closure encoding (mk would need to support procedure values)
;   de bruin encoding (with and without integer support)
;   raw interpretation
;   original relational interpreter(s) (mk only)


(define (evalo expr val)
  (eval-expo expr initial-env val))

(define (eval-expo expr env val)
  (try-lookup-before expr env val (eval-expo-rest expr env val)))

(define (paramso params)
  ;(list-of-symbolso params)
  (conde$-dfs
    ; Multiple argument
    ((list-of-symbolso params))
    ; Variadic
    ((symbolo params)))
  )

(define (eval-expo-rest expr env val)
  (lambdag@ (st)
    (let* ((expr (walk expr (state-S st)))
           (env (walk env (state-S st)))
           (depth (state-depth st))
           (goal (lambdag@ (st)
                   ((conde-weighted
   (5000 1 (conde$-dfs ((== `(quote ,val) expr)
                      (absento closure-tag val)
                      (absento prim-tag val)
                      (not-in-envo 'quote env))

                     ((numbero expr) (== expr val))

                     ((prim-expo expr env val))

                     ((fresh (rator rands rator-val)
                        (== `(,rator . ,rands) expr)
                        (eval-expo rator env rator-val)
                        (conde-dfs
                          ((fresh (prim-id)
                             (== rator-val `(,prim-tag . ,prim-id))
                             (eval-primo prim-id val rands env)))
                          ((fresh (x body env^ a* res)
                             (== rator-val `(,closure-tag (lambda ,x ,body) ,env^))
                             (conde$-dfs
                               (;; Multi-argument
                                (ext-env*o x a* env^ res)
                                ; replacing eval-application with these may be faster with multi-level defer
                                ;(eval-expo body res val)
                                ;(eval-listo rands env a*)
                                (eval-application rands env a* (eval-expo body res val)))
                               (;; variadic
                                (symbolo x)
                                ;(project (rator) (lambdag@ (st) ((begin (display `(happened ,rator)) (newline) succeed) st)))
                                (== `((,x . (val . ,a*)) . ,env^) res)
                                (eval-expo body res val)
                                (eval-listo rands env a*))))))))))

   (5000 #f (if-primo expr env val))

   (1 1 (fresh (x body)
        (== `(lambda ,x ,body) expr)
        (== `(,closure-tag (lambda ,x ,body) ,env) val)
        (paramso x)
        (not-in-envo 'lambda env)))

   ;; WEB 25 May 2016 -- This rather budget version of 'begin' is
   ;; useful for separating 'define' from the expression 'e',
   ;; specifically for purposes of Barliman.
   (1 1 (fresh (defn args name body e)
        (== `(begin ,defn ,e) expr)
        (== `(define ,name (lambda ,args ,body)) defn)
        (eval-expo `(letrec ((,name (lambda ,args ,body))) ,e) env val)))

   (1 1 (fresh (p-name x body letrec-body)
        ;; single-function variadic letrec version
        (== `(letrec ((,p-name (lambda ,x ,body)))
               ,letrec-body)
            expr)
        (paramso x)
        (conde$ ((symbolo x) (project (x) (lambdag@ (st) ((begin (display `(letrec ,p-name ,x)) (newline) fail) st)))) (succeed))
        (not-in-envo 'letrec env)
        (eval-expo letrec-body
                   `((,p-name . (rec . (lambda ,x ,body))) . ,env)
                   val)))


   )
                    (state-depth-set st depth)))))

      (if (or (var? expr)
              (var? env)
              (and (pair? expr) (var? (walk (car expr) (state-S st)))))
        (state-deferred-defer st goal)
        (goal st)))))

(define (lookupo x env t)
  (fresh (y b rest)
    (== `((,y . ,b) . ,rest) env)
    (conde;1 (((x x) (y y)))
      ((== x y)
       (conde;1 (((b b)))
         ((== `(val . ,t) b))
         ((fresh (lam-expr)
            (== `(rec . ,lam-expr) b)
            (== `(,closure-tag ,lam-expr ,env) t)))))
      ((=/= x y)
       (lookupo x rest t)))))

(define (try-lookup-before x env t alts)
  (lambdag@ (st)
    (let-values (((rgenv venv) (list-split-ground st env)))
      (let loop ((rgenv rgenv) (alts (conde$ ;1$ (((x x)))
                                       ((symbolo x) (lookupo x venv t))
                                       (alts))))
        (if (null? rgenv) (alts st)
          (let ((rib (car rgenv)))
            (loop (cdr rgenv)
              (fresh (y b)
                (== `(,y . ,b) rib)
                (conde$ ;1$ ((;(x x)
                           ;(y y)
                           ;))
                  ((symbolo x) (== x y)
                   (conde$ ;1$ (((b b)))
                     ((== `(val . ,t) b))
                     ((fresh (lam-expr)
                             (== `(rec . ,lam-expr) b)
                             (== `(,closure-tag ,lam-expr ,env) t)))))
                  ((=/= x y) alts))))))))))

(define (not-in-envo x env)
  (conde1 (((x x) (env env)))
    ((== empty-env env))
    ((fresh (y b rest)
       (== `((,y . ,b) . ,rest) env)
       (=/= y x)
       (not-in-envo x rest)))))

(define (eval-listo expr env val)
  (conde1 (((expr expr)) ((val val)))
    ((== '() expr)
     (== '() val))
    ((fresh (a d v-a v-d)
            (== `(,a . ,d) expr)
            (== `(,v-a . ,v-d) val)
            (eval-expo a env v-a)
            (eval-listo d env v-d)))))

(define (list-split-ground st xs)
  (let loop ((rprefix '()) (xs xs))
    (let ((tm (walk xs (state-S st))))
      (if (pair? tm)
        (loop (cons (walk (car tm) (state-S st)) rprefix) (cdr tm))
        (values rprefix xs)))))

(define (eval-application rands aenv a* body-goal)
  (define succeed unit)
  (lambdag@ (st)
    (let-values (((rrands rands-suffix) (list-split-ground st rands)))
      (let-values
        (((ggoals vgoals args-suffix)
          (let loop ((rands (reverse rrands))
                     (ggoals succeed)
                     (vgoals succeed)
                     (args a*))
            (if (null? rands) (values ggoals vgoals args)
              (let ((rand (car rands)))
                (let/vars st (args-rest)
                  (let ((goal (fresh (arg)
                                (== `(,arg . ,args-rest) args)
                                (eval-expo rand aenv arg))))
                    (if (var? rand)
                      (loop (cdr rands) ggoals (fresh () vgoals goal) args-rest)
                      (loop (cdr rands) (fresh () ggoals goal) vgoals args-rest)))))))))
        ((fresh ()
           ggoals    ; try ground arguments first
           body-goal ; then the body
           vgoals    ; then fill in unbound arguments
           ; any unbound final segment of arguments
           (eval-listo rands-suffix aenv args-suffix)) st)))))

;; need to make sure lambdas are well formed.
;; grammar constraints would be useful here!!!
(define (list-of-symbolso los)
  (conde1 (((los los)))
    ((== '() los))
    ((fresh (a d)
       (== `(,a . ,d) los)
       (symbolo a)
       (list-of-symbolso d)))))

(define (ext-env*o x* a* env out)
  (conde;1 (((x* x*)) ((a* a*)))
    ((== '() x*) (== '() a*) (== env out))
    ((fresh (x a dx* da* env2)
       (== `(,x . ,dx*) x*)
       (== `(,a . ,da*) a*)
       (== `((,x . (val . ,a)) . ,env) env2)
       (symbolo x)
       (ext-env*o dx* da* env2 out)))))

(define (eval-primo prim-id val rands env)
  (project0 (prim-id val rands env)
    (conde$ ;1$ (((prim-id prim-id)))
      [(== prim-id 'cons)
       (fresh (a d)
         (== `(,a . ,d) val)
         (eval-listo rands env `(,a ,d)))]
      [(== prim-id 'car)
       (fresh (d)
         (=/= closure-tag val)
         (eval-listo rands env `((,val . ,d))))]
      [(== prim-id 'cdr)
       (fresh (a)
         (=/= closure-tag a)
         (eval-listo rands env `((,a . ,val))))]
      [(== prim-id 'null?)
       (fresh (v)
         (let ((assign-result (conde$
                                ((== '() v) (== #t val))
                                ((=/= '() v) (== #f val))))
               (eval-args (eval-listo rands env `(,v))))
           (if (var? val)
             (fresh () eval-args assign-result)
             (fresh () assign-result eval-args))))]
      [(== prim-id 'pair?)
       (fresh (v)
         (let ((assign-true (fresh (a d) (== #t val) (== `(,a . ,d) v)))
               (assign-false (fresh () (== #f val) (conde$
                                                     ((== '() v))
                                                     ((symbolo v))
                                                     ((== #f v))
                                                     ((== #t v))
                                                     ((numbero v)))))
               (eval-args (eval-listo rands env `(,v))))
           (if (or (var? val) (eq? val #f))
             (fresh () eval-args (conde$ (assign-true) (assign-false)))
             (fresh () assign-true eval-args))))]
      [(== prim-id 'symbol?)
       (fresh (v)
         (let ((assign-true (fresh () (== #t val) (symbolo v)))
               (assign-false (fresh () (== #f val) (conde$
                                                     ((== '() v))
                                                     ((fresh (a d)
                                                        (== `(,a . ,d) v)))
                                                     ((== #f v))
                                                     ((== #t v))
                                                     ((numbero v)))))
               (eval-args (eval-listo rands env `(,v))))
           (if (or (var? val) (eq? val #f))
             (fresh () eval-args (conde$ (assign-true) (assign-false)))
             (fresh () assign-true eval-args))))]
      [(== prim-id 'not)
       (fresh (b)
         (let ((assign-result (conde$
                                ((== #f b) (== #t val))
                                ((=/= #f b) (== #f val))))
               (eval-args (eval-listo rands env `(,b))))
           (if (var? val)
             (fresh () eval-args assign-result)
             (fresh () assign-result eval-args))))]
      [(== prim-id 'equal?)
       (fresh (v1 v2)
         (let ((assign-result (conde$
                                ((== v1 v2) (== #t val))
                                ((=/= v1 v2) (== #f val))))
               (eval-args (eval-listo rands env `(,v1 ,v2))))
           (if (var? val)
             (fresh () eval-args assign-result)
             (fresh () assign-result eval-args))))]
      [(== prim-id 'list)
       (eval-listo rands env val)])))

(define (prim-expo expr env val)
  (conde1$ (((expr expr)))
    ((boolean-primo expr env val))
    ))

(define (boolean-primo expr env val)
  (conde1$ (((expr expr)) ((val val)))
    ((== #t expr) (== #t val))
    ((== #f expr) (== #f val))))

;; Set this flag to #f to recover Scheme semantics.
(define boolean-conditions-only? #t)
(define (condition v)
  (if (and allow-incomplete-search? boolean-conditions-only?)
    (booleano v)
    unit))
(define (condition-true v)
  (if (and allow-incomplete-search? boolean-conditions-only?)
    (== #t v)
    (=/= #f v)))

(define (if-primo expr env val)
  (fresh (e1 e2 e3 t)
    (== `(if ,e1 ,e2 ,e3) expr)
    (not-in-envo 'if env)
    (eval-expo e1 env t)
    (conde1 (((t t)))
      ((condition-true t) (eval-expo e2 env val))
      ((== #f t) (eval-expo e3 env val)))))

(define initial-env `((cons . (val . (,prim-tag . cons)))
                      (car . (val . (,prim-tag . car)))
                      (cdr . (val . (,prim-tag . cdr)))
                      (null? . (val . (,prim-tag . null?)))
                      (pair? . (val . (,prim-tag . pair?)))
                      (symbol? . (val . (,prim-tag . symbol?)))
                      (not . (val . (,prim-tag . not)))
                      (equal? . (val . (,prim-tag . equal?)))
                      (list . (val . (,prim-tag . list)))
                      ;(list . (val . (,closure-tag (lambda x x) ,empty-env)))
                      . ,empty-env))

(define (booleano t)
  (conde1$ (((t t)))
    ((== #f t))
    ((== #t t))))


;; Tests

(time (test 'list-nth-element-peano
  (run 1 (q r)
    (evalo `(begin
              (define nth
                (lambda (n xs)
                  (if (null? n) ,q ,r)))
              (list
                (nth '() '(foo bar))
                (nth '(s) '(foo bar))
                (nth '() '(1 2 3))
                (nth '(s) '(1 2 3))
                (nth '(s s) '(1 2 3))))
           (list 'foo 'bar 1 2 3)))
  '((((car xs) (nth (cdr n) (cdr xs)))))))

(time
 (test 'map-hard-0-gensym
   (run 1 (defn)
     (let ((g1 (gensym "g1"))
           (g2 (gensym "g2"))
           (g3 (gensym "g3"))
           (g4 (gensym "g4"))
           (g5 (gensym "g5"))
           (g6 (gensym "g6"))
           (g7 (gensym "g7")))
       (fresh ()
         (absento g1 defn)
         (absento g2 defn)
         (absento g3 defn)
         (absento g4 defn)
         (absento g5 defn)
         (absento g6 defn)
         (absento g7 defn)
         (== `(define map
                (lambda (f xs)
                  (if (null? xs)
                    xs (cons (f (car xs)) (map f (cdr xs))))))
             defn)
         (evalo `(begin
                   ,defn
                   (list
                     (map ',g1 '())
                     (map car '((,g2 . ,g3)))
                     (map cdr '((,g4 . ,g5) (,g6 . ,g7)))))
                (list '() `(,g2) `(,g5 ,g7))))))
   '(((define map
        (lambda (f xs)
          (if (null? xs)
            xs (cons (f (car xs)) (map f (cdr xs))))))))))

(time
 (test 'map-hard-1-gensym
   (run 1 (defn)
     (let ((g1 (gensym "g1"))
           (g2 (gensym "g2"))
           (g3 (gensym "g3"))
           (g4 (gensym "g4"))
           (g5 (gensym "g5"))
           (g6 (gensym "g6"))
           (g7 (gensym "g7")))
       (fresh (a b c)
         (absento g1 defn)
         (absento g2 defn)
         (absento g3 defn)
         (absento g4 defn)
         (absento g5 defn)
         (absento g6 defn)
         (absento g7 defn)
         (== `(define map
                (lambda (f xs)
                  (if (null? xs)
                    ,a (cons ,b (map f ,c)))))
           defn)
         (evalo `(begin
                   ,defn
                   (list
                     (map ',g1 '())
                     (map car '((,g2 . ,g3)))
                     (map cdr '((,g4 . ,g5) (,g6 . ,g7)))))
                (list '() `(,g2) `(,g5 ,g7))))))
   '(((define map
        (lambda (f xs)
          (if (null? xs)
            xs (cons (f (car xs)) (map f (cdr xs))))))))))

(time
 (test 'map-hard-2-gensym
   (run 1 (defn)
     (let ((g1 (gensym "g1"))
           (g2 (gensym "g2"))
           (g3 (gensym "g3"))
           (g4 (gensym "g4"))
           (g5 (gensym "g5"))
           (g6 (gensym "g6"))
           (g7 (gensym "g7")))
       (fresh (a)
         (absento g1 defn)
         (absento g2 defn)
         (absento g3 defn)
         (absento g4 defn)
         (absento g5 defn)
         (absento g6 defn)
         (absento g7 defn)
         (== `(define map
                (lambda (f xs)
                  (if (null? xs)
                    xs (cons (f (car xs)) (map ,a (cdr xs))))))
             defn)
         (evalo `(begin
                   ,defn
                   (list
                     (map ',g1 '())
                     (map car '((,g2 . ,g3)))
                     (map cdr '((,g4 . ,g5) (,g6 . ,g7)))))
                (list '() `(,g2) `(,g5 ,g7))))))
   '(((define map
        (lambda (f xs)
          (if (null? xs)
            xs (cons (f (car xs)) (map f (cdr xs))))))))))

;(time
 ;(test 'map-hard-3-gensym
   ;(run 1 (defn)
     ;(let ((g1 (gensym "g1"))
           ;(g2 (gensym "g2"))
           ;(g3 (gensym "g3"))
           ;(g4 (gensym "g4"))
           ;(g5 (gensym "g5"))
           ;(g6 (gensym "g6"))
           ;(g7 (gensym "g7")))
       ;(fresh (a)
         ;(absento g1 defn)
         ;(absento g2 defn)
         ;(absento g3 defn)
         ;(absento g4 defn)
         ;(absento g5 defn)
         ;(absento g6 defn)
         ;(absento g7 defn)
         ;(== `(define map
                ;(lambda (f xs) ,a))
             ;defn)
         ;(evalo `(begin
                   ;,defn
                   ;(list
                     ;(map ',g1 '())
                     ;(map car '((,g2 . ,g3)))
                     ;(map cdr '((,g4 . ,g5) (,g6 . ,g7)))))
                ;(list '() `(,g2) `(,g5 ,g7))))))
   ;'(((define map
        ;(lambda (f xs)
          ;(if (null? xs)
            ;xs (cons (f (car xs)) (map f (cdr xs))))))))))

;(time
 ;(test 'map-hard-4-gensym
   ;(run 1 (defn)
     ;(let ((g1 (gensym "g1"))
           ;(g2 (gensym "g2"))
           ;(g3 (gensym "g3"))
           ;(g4 (gensym "g4"))
           ;(g5 (gensym "g5"))
           ;(g6 (gensym "g6"))
           ;(g7 (gensym "g7")))
       ;(fresh ()
         ;(absento g1 defn)
         ;(absento g2 defn)
         ;(absento g3 defn)
         ;(absento g4 defn)
         ;(absento g5 defn)
         ;(absento g6 defn)
         ;(absento g7 defn)
         ;(evalo `(begin
                   ;,defn
                   ;(list
                     ;(map ',g1 '())
                     ;(map car '((,g2 . ,g3)))
                     ;(map cdr '((,g4 . ,g5) (,g6 . ,g7)))))
                ;(list '() `(,g2) `(,g5 ,g7))))))
   ;'(((define map
        ;(lambda (_.0 _.1)
          ;(if (null? _.1)
            ;_.1 (cons (_.0 (car _.1)) (map _.0 (cdr _.1))))))
      ;(sym _.0 _.1)))))

(test 'append-empty
  (run 1 (q)
       (evalo
         `(begin
            (define append
              (lambda (l s)
                (if (null? l)
                  s
                  (cons (car l)
                        (append (cdr l) s)))))
            (append '() '()))
         '()))
  '((_.0)))

(test 'append-all-answers
  (run* (l1 l2)
        (evalo `(begin
                  (define append
                    (lambda (l s)
                      (if (null? l)
                        s
                        (cons (car l)
                              (append (cdr l) s)))))
                  (append ',l1 ',l2))
               '(1 2 3 4 5)))
  '(((() (1 2 3 4 5)))
    (((1) (2 3 4 5)))
    (((1 2) (3 4 5)))
    (((1 2 3) (4 5)))
    (((1 2 3 4) (5)))
    (((1 2 3 4 5) ()))))

;;; flipping rand/body eval order makes this one too hard,
;;; but dynamic ordering via eval-application fixes it!
(test 'append-cons-first-arg
  (run 1 (q)
    (evalo `(begin (define append
                     (lambda (l s)
                       (if (null? l)
                         s
                         (cons ,q
                               (append (cdr l) s)))))
                   (append '(1 2 3) '(4 5)))
           '(1 2 3 4 5)))
  '(((car l))))

(test 'append-cdr-arg
  (run 1 (q)
       (evalo `(begin
                 (define append
                   (lambda (l s)
                     (if (null? l)
                       s
                       (cons (car l)
                             (append (cdr ,q) s)))))
                 (append '(1 2 3) '(4 5)))
              '(1 2 3 4 5)))
  '((l)))

(test 'append-cdr
  (run 1 (q)
    (evalo `(begin
              (define append
                (lambda (l s)
                  (if (null? l)
                    s
                    (cons (car l)
                          (append (,q l) s)))))
              (append '(1 2 3) '(4 5)))
           '(1 2 3 4 5)))
  '((cdr)))

(time (test 'append-hard-1
  (run 1 (q r)
    (evalo `(begin
              (define append
                (lambda (l s)
                  (if (null? l)
                    s
                    (cons (car l)
                          (append (,q ,r) s)))))
              (append '(1 2 3) '(4 5)))
           '(1 2 3 4 5)))
  '(((cdr l)))))

(time (test 'append-hard-2
  (run 1 (q)
    (evalo `(begin
              (define append
                (lambda (l s)
                  (if (null? l)
                    s
                    (cons (car l)
                          (append ,q s)))))
              (append '(1 2 3) '(4 5)))
           '(1 2 3 4 5)))
  '(((cdr l)))))

(time (test 'append-hard-3
  (run 1 (q r)
    (evalo `(begin
              (define append
                (lambda (l s)
                  (if (null? l)
                    s
                    (cons (car l)
                          (append ,q ,r)))))
              (list
                (append '(foo) '(bar))
                (append '(1 2 3) '(4 5))))
           (list '(foo bar) '(1 2 3 4 5))))
  '((((cdr l) s)))))

(time (test 'append-hard-4
  (run 1 (q)
    (evalo `(begin
              (define append
                (lambda (l s)
                  (if (null? l)
                    s
                    (cons (car l)
                          (append . ,q)))))
              (list
                (append '(foo) '(bar))
                (append '(1 2 3) '(4 5))))
           (list '(foo bar) '(1 2 3 4 5))))
  '((((cdr l) s)))))

(time (test 'append-hard-5
  (run 1 (q r)
    (evalo `(begin
              (define append
                (lambda (l s)
                  (if (null? l)
                    s
                    (cons ,q
                          (append . ,r)))))
              (list
                (append '() '())
                (append '(foo) '(bar))
                (append '(1 2 3) '(4 5))))
           (list '() '(foo bar) '(1 2 3 4 5))))
  '((((car l) ((cdr l) s))))))

;; the following are still overfitting
;; probably need to demote quote and some others

(time
 (test 'append-hard-6-gensym-dummy-test
   (run 1 (defn)
     (let ((g1 (gensym "g1"))
           (g2 (gensym "g2"))
           (g3 (gensym "g3"))
           (g4 (gensym "g4"))
           (g5 (gensym "g5"))
           (g6 (gensym "g6"))
           (g7 (gensym "g7")))
       (fresh ()
         (absento g1 defn)
         (absento g2 defn)
         (absento g3 defn)
         (absento g4 defn)
         (absento g5 defn)
         (absento g6 defn)
         (absento g7 defn)
         (fresh (q a b)

           (== `(append ,a ,b) q)

           (== `(define append
                  (lambda (l s)
                    (if (null? l)
                        s
                        (cons (car l) ,q))))
               defn)
           (evalo `(begin
                     ,defn
                     (list
                      (append '() '())
                      (append '(,g1) '(,g2))
                      (append '(,g3 ,g4 ,g5) '(,g6 ,g7))))
                  (list '() `(,g1 ,g2) `(,g3 ,g4 ,g5 ,g6 ,g7)))))))
   '(((define append (lambda (l s) (if (null? l) s (cons (car l) (append (cdr l) s)))))))))

(printf "append-hard-6-gensym-less-dummy-test takes ~~16s\n")
(time
 (test 'append-hard-6-gensym-less-dummy-test
   (run 1 (defn)
     (let ((g1 (gensym "g1"))
           (g2 (gensym "g2"))
           (g3 (gensym "g3"))
           (g4 (gensym "g4"))
           (g5 (gensym "g5"))
           (g6 (gensym "g6"))
           (g7 (gensym "g7")))
       (fresh ()
         (absento g1 defn)
         (absento g2 defn)
         (absento g3 defn)
         (absento g4 defn)
         (absento g5 defn)
         (absento g6 defn)
         (absento g7 defn)
         (fresh (q a b c)

           (== `(,a ,b ,c) q)

           (== `(define append
                  (lambda (l s)
                    (if (null? l)
                        s
                        (cons (car l) ,q))))
               defn)
           (evalo `(begin
                     ,defn
                     (list
                      (append '() '())
                      (append '(,g1) '(,g2))
                      (append '(,g3 ,g4 ,g5) '(,g6 ,g7))))
                  (list '() `(,g1 ,g2) `(,g3 ,g4 ,g5 ,g6 ,g7)))))))
   '(((define append (lambda (l s) (if (null? l) s (cons (car l) (append (cdr l) s)))))))))

(printf "append-hard-6-no-gensym returns an over-specific, incorrect answer\n")
(time (test 'append-hard-6-no-gensym
  (run 1 (q)
    (evalo `(begin
              (define append
                (lambda (l s)
                  (if (null? l)
                    s
                    (cons (car l) ,q))))
              (list
                (append '() '())
                (append '(foo) '(bar))
                (append '(1 2 3) '(4 5))))
           (list '() '(foo bar) '(1 2 3 4 5))))
  '(((append (cdr l) s)))))

(time
 (test 'append-hard-6-gensym
   (run 1 (defn)
     (let ((g1 (gensym "g1"))
           (g2 (gensym "g2"))
           (g3 (gensym "g3"))
           (g4 (gensym "g4"))
           (g5 (gensym "g5"))
           (g6 (gensym "g6"))
           (g7 (gensym "g7")))
       (fresh ()
         (absento g1 defn)
         (absento g2 defn)
         (absento g3 defn)
         (absento g4 defn)
         (absento g5 defn)
         (absento g6 defn)
         (absento g7 defn)
         (fresh (q)
           (== `(define append
                  (lambda (l s)
                    (if (null? l)
                        s
                        (cons (car l) ,q))))
               defn)
           (evalo `(begin
                     ,defn
                     (list
                      (append '() '())
                      (append '(,g1) '(,g2))
                      (append '(,g3 ,g4 ,g5) '(,g6 ,g7))))
                  (list '() `(,g1 ,g2) `(,g3 ,g4 ,g5 ,g6 ,g7)))))))
   '(((define append (lambda (l s) (if (null? l) s (cons (car l) (append (cdr l) s)))))))))

(time
 (test 'append-hard-7-gensym
   (run 1 (defn)
     (let ((g1 (gensym "g1"))
           (g2 (gensym "g2"))
           (g3 (gensym "g3"))
           (g4 (gensym "g4"))
           (g5 (gensym "g5"))
           (g6 (gensym "g6"))
           (g7 (gensym "g7")))
       (fresh ()
         (absento g1 defn)
         (absento g2 defn)
         (absento g3 defn)
         (absento g4 defn)
         (absento g5 defn)
         (absento g6 defn)
         (absento g7 defn)
         (fresh (q r)
           (== `(define append
                  (lambda (l s)
                    (if (null? l)
                        s
                        (cons ,q ,r))))
               defn)
           (evalo `(begin
                     ,defn
                     (list
                      (append '() '())
                      (append '(,g1) '(,g2))
                      (append '(,g3 ,g4 ,g5) '(,g6 ,g7))))
                  (list '() `(,g1 ,g2) `(,g3 ,g4 ,g5 ,g6 ,g7)))))))
   '(((define append (lambda (l s) (if (null? l) s (cons (car l) (append (cdr l) s)))))))))

(test 'append-hard-7-no-gensym
  (run 1 (q r)
    (evalo `(begin
              (define append
                (lambda (l s)
                  (if (null? l)
                    s
                    (cons ,q ,r))))
              (list
                (append '() '())
                (append '(foo) '(bar))
                (append '(1 2 3) '(4 5))))
           (list '() '(foo bar) '(1 2 3 4 5))))
  '((((car l) (append (cdr l) s)))))

(time
 (test 'append-hard-8-gensym
   (run 1 (defn)
     (let ((g1 (gensym "g1"))
           (g2 (gensym "g2"))
           (g3 (gensym "g3"))
           (g4 (gensym "g4"))
           (g5 (gensym "g5"))
           (g6 (gensym "g6"))
           (g7 (gensym "g7")))
       (fresh ()
         (absento g1 defn)
         (absento g2 defn)
         (absento g3 defn)
         (absento g4 defn)
         (absento g5 defn)
         (absento g6 defn)
         (absento g7 defn)
         (fresh (q)
           (== `(define append
                  (lambda (l s)
                    (if (null? l)
                        s
                        ,q)))
               defn)
           (evalo `(begin
                     ,defn
                     (list
                      (append '() '())
                      (append '(,g1) '(,g2))
                      (append '(,g3 ,g4 ,g5) '(,g6 ,g7))))
                  (list '() `(,g1 ,g2) `(,g3 ,g4 ,g5 ,g6 ,g7)))))))
   '(((define append (lambda (l s) (if (null? l) s (cons (car l) (append (cdr l) s)))))))))

(time
 (test 'append-hard-9-gensym
   (run 1 (defn)
     (let ((g1 (gensym "g1"))
           (g2 (gensym "g2"))
           (g3 (gensym "g3"))
           (g4 (gensym "g4"))
           (g5 (gensym "g5"))
           (g6 (gensym "g6"))
           (g7 (gensym "g7")))
       (fresh ()
         (absento g1 defn)
         (absento g2 defn)
         (absento g3 defn)
         (absento g4 defn)
         (absento g5 defn)
         (absento g6 defn)
         (absento g7 defn)
         (fresh (q r)
           (== `(define append
                  (lambda (l s)
                    (if (null? l)
                        ,q
                        ,r)))
               defn)
           (evalo `(begin
                     ,defn
                     (list
                      (append '() '())
                      (append '(,g1) '(,g2))
                      (append '(,g3 ,g4 ,g5) '(,g6 ,g7))))
                  (list '() `(,g1 ,g2) `(,g3 ,g4 ,g5 ,g6 ,g7)))))))
   '(((define append (lambda (l s) (if (null? l) s (cons (car l) (append (cdr l) s)))))))))

(time
 (test 'append-hard-10-gensym
   (run 1 (defn)
     (let ((g1 (gensym "g1"))
           (g2 (gensym "g2"))
           (g3 (gensym "g3"))
           (g4 (gensym "g4"))
           (g5 (gensym "g5"))
           (g6 (gensym "g6"))
           (g7 (gensym "g7")))
       (fresh ()
         (absento g1 defn)
         (absento g2 defn)
         (absento g3 defn)
         (absento g4 defn)
         (absento g5 defn)
         (absento g6 defn)
         (absento g7 defn)
         (fresh (q r s)
           (== `(define append
                  (lambda (l s)
                    (if (null? ,q)
                        ,r
                        ,s)))
               defn)
           (evalo `(begin
                     ,defn
                     (list
                      (append '() '())
                      (append '(,g1) '(,g2))
                      (append '(,g3 ,g4 ,g5) '(,g6 ,g7))))
                  (list '() `(,g1 ,g2) `(,g3 ,g4 ,g5 ,g6 ,g7)))))))
   '(((define append (lambda (l s) (if (null? l) s (cons (car l) (append (cdr l) s)))))))))

(time
 (test 'append-hard-11-gensym
   (run 1 (defn)
     (let ((g1 (gensym "g1"))
           (g2 (gensym "g2"))
           (g3 (gensym "g3"))
           (g4 (gensym "g4"))
           (g5 (gensym "g5"))
           (g6 (gensym "g6"))
           (g7 (gensym "g7")))
       (fresh ()
         (absento g1 defn)
         (absento g2 defn)
         (absento g3 defn)
         (absento g4 defn)
         (absento g5 defn)
         (absento g6 defn)
         (absento g7 defn)
         (fresh (q r s t)
           (== `(define append
                  (lambda (l s)
                    (if (,t ,q)
                        ,r
                        ,s)))
               defn)
           (evalo `(begin
                     ,defn
                     (list
                      (append '() '())
                      (append '(,g1) '(,g2))
                      (append '(,g3 ,g4 ,g5) '(,g6 ,g7))))
                  (list '() `(,g1 ,g2) `(,g3 ,g4 ,g5 ,g6 ,g7)))))))
   '(((define append (lambda (l s) (if (null? l) s (cons (car l) (append (cdr l) s)))))))))

(time
  (test 'append-equal-0
        (run 1 (defn)
          (let ((g1 (gensym "g1"))
                (g2 (gensym "g2"))
                (g3 (gensym "g3"))
                (g4 (gensym "g4"))
                (g5 (gensym "g5"))
                (g6 (gensym "g6"))
                (g7 (gensym "g7")))
            (fresh ()
              (absento g1 defn)
              (absento g2 defn)
              (absento g3 defn)
              (absento g4 defn)
              (absento g5 defn)
              (absento g6 defn)
              (absento g7 defn)
              (evalo `(begin
                        ,defn
                        (list
                          (equal? '() (append '() '()))
                          (equal? (list ',g1 ',g2) (append '(,g1) '(,g2)))
                          (equal? (list ',g3 ',g4 ',g5 ',g6) (append '(,g3 ,g4) '(,g5 ,g6)))))
                     (list #t #t #t)))))
        '(((define append
             (lambda (_.0 _.1)
               (if (null? _.0)
                 _.1
                 (cons (car _.0) (append (cdr _.0) _.1)))))
           (sym _.0 _.1)))))

(time
  (test 'append-equal-1
        (run 1 (defn)
          (let ((g1 (gensym "g1"))
                (g2 (gensym "g2"))
                (g3 (gensym "g3"))
                (g4 (gensym "g4"))
                (g5 (gensym "g5"))
                (g6 (gensym "g6"))
                (g7 (gensym "g7")))
            (fresh ()
              (absento g1 defn)
              (absento g2 defn)
              (absento g3 defn)
              (absento g4 defn)
              (absento g5 defn)
              (absento g6 defn)
              (absento g7 defn)
              (evalo `(begin
                        ,defn
                        (list
                          (equal? (append '() '()) '())
                          (equal? (append '(,g1) '(,g2)) (list ',g1 ',g2))
                          (equal? (append '(,g3 ,g4) '(,g5 ,g6)) (list ',g3 ',g4 ',g5 ',g6))))
                     (list #t #t #t)))))
        '(((define append
             (lambda (_.0 _.1)
               (if (null? _.0)
                 _.1
                 (cons (car _.0) (append (cdr _.0) _.1)))))
           (sym _.0 _.1)))))

(time
  (test 'interp-0
    (run 1 (defn)
      (let ((g1 (gensym "g1"))
            (g2 (gensym "g2"))
            (g3 (gensym "g3"))
            (g4 (gensym "g4"))
            (g5 (gensym "g5"))
            (g6 (gensym "g6"))
            (g7 (gensym "g7")))
        (fresh (a b c d)
          (absento g1 defn)
          (absento g2 defn)
          (absento g3 defn)
          (absento g4 defn)
          (absento g5 defn)
          (absento g6 defn)
          (absento g7 defn)
          (== `(define eval-expr
                 (lambda (expr env)
                   (match expr
                     [`(quote ,datum) datum]
                     [`(lambda (,(? symbol? x)) ,body)
                       (lambda (a)
                         (eval-expr body (lambda (y)
                                           (if (equal? ,a ,b)
                                             ,c
                                             (env ,d)))))]
                     [(? symbol? x) (env x)]
                     [`(cons ,e1 ,e2) (cons (eval-expr e1 env) (eval-expr e2 env))]
                     [`(,rator ,rand) ((eval-expr rator env) (eval-expr rand env))])))
              defn)
          (evalo `(begin
                    ,defn
                    (list
                      (eval-expr '((lambda (y) y) ',g1) 'initial-env)
                      (eval-expr '(((lambda (z) z) (lambda (v) v)) ',g2) 'initial-env)
                      (eval-expr '(((lambda (a) (a a)) (lambda (b) b)) ',g3) 'initial-env)
                      (eval-expr '(((lambda (c) (lambda (d) c)) ',g4) ',g5) 'initial-env)
                      (eval-expr '(((lambda (f) (lambda (v1) (f (f v1)))) (lambda (e) e)) ',g6) 'initial-env)
                      (eval-expr '((lambda (g) ((g g) g)) (lambda (i) (lambda (j) ',g7))) 'initial-env)
                      ))
                 (list
                   g1
                   g2
                   g3
                   g4
                   g6
                   g7
                   )))))
    '(((define eval-expr
         (lambda (expr env)
           (match expr
             [`(quote ,datum) datum]
             [`(lambda (,(? symbol? x)) ,body)
               (lambda (a)
                 (eval-expr body (lambda (y)
                                   (if (equal? y x)
                                     a
                                     (env y)))))]
             [(? symbol? x) (env x)]
             [`(cons ,e1 ,e2) (cons (eval-expr e1 env) (eval-expr e2 env))]
             [`(,rator ,rand) ((eval-expr rator env) (eval-expr rand env))])))))))

;(time
  ;(test 'interp-1
    ;(run 1 (defn)
      ;(let ((g1 (gensym "g1"))
            ;(g2 (gensym "g2"))
            ;(g3 (gensym "g3"))
            ;(g4 (gensym "g4"))
            ;(g5 (gensym "g5"))
            ;(g6 (gensym "g6"))
            ;(g7 (gensym "g7")))
        ;(fresh (a b c d)
          ;(absento g1 defn)
          ;(absento g2 defn)
          ;(absento g3 defn)
          ;(absento g4 defn)
          ;(absento g5 defn)
          ;(absento g6 defn)
          ;(absento g7 defn)
          ;(== `(define eval-expr
                 ;(lambda (expr env)
                   ;(match expr
                     ;[`(quote ,datum) datum]
                     ;[`(lambda (,(? symbol? x)) ,body)
                       ;(lambda (a)
                         ;(eval-expr body (lambda (y)
                                           ;(if (equal? ,a ,b)
                                             ;,c
                                             ;,d))))]
                     ;[(? symbol? x) (env x)]
                     ;[`(cons ,e1 ,e2) (cons (eval-expr e1 env) (eval-expr e2 env))]
                     ;[`(,rator ,rand) ((eval-expr rator env) (eval-expr rand env))])))
              ;defn)
          ;(evalo `(begin
                    ;,defn
                    ;(list
                      ;(eval-expr '((lambda (y) y) ',g1) 'initial-env)
                      ;(eval-expr '(((lambda (z) z) (lambda (v) v)) ',g2) 'initial-env)
                      ;(eval-expr '(((lambda (a) (a a)) (lambda (b) b)) ',g3) 'initial-env)
                      ;(eval-expr '(((lambda (c) (lambda (d) c)) ',g4) ',g5) 'initial-env)
                      ;(eval-expr '(((lambda (f) (lambda (v1) (f (f v1)))) (lambda (e) e)) ',g6) 'initial-env)
                      ;(eval-expr '((lambda (g) ((g g) g)) (lambda (i) (lambda (j) ',g7))) 'initial-env)
                      ;))
                 ;(list
                   ;g1
                   ;g2
                   ;g3
                   ;g4
                   ;g6
                   ;g7
                   ;)))))
    ;'(((define eval-expr
         ;(lambda (expr env)
           ;(match expr
             ;[`(quote ,datum) datum]
             ;[`(lambda (,(? symbol? x)) ,body)
               ;(lambda (a)
                 ;(eval-expr body (lambda (y)
                                   ;(if (equal? y x)
                                     ;a
                                     ;(env y)))))]
             ;[(? symbol? x) (env x)]
             ;[`(cons ,e1 ,e2) (cons (eval-expr e1 env) (eval-expr e2 env))]
             ;[`(,rator ,rand) ((eval-expr rator env) (eval-expr rand env))])))))))

(time
 (test 'append-hard-12-gensym
   (run 1 (defn)
     (let ((g1 (gensym "g1"))
           (g2 (gensym "g2"))
           (g3 (gensym "g3"))
           (g4 (gensym "g4"))
           (g5 (gensym "g5"))
           (g6 (gensym "g6"))
           (g7 (gensym "g7")))
       (fresh ()
         (absento g1 defn)
         (absento g2 defn)
         (absento g3 defn)
         (absento g4 defn)
         (absento g5 defn)
         (absento g6 defn)
         (absento g7 defn)
         (fresh (q r s)
           (== `(define append
                  (lambda (l s)
                    (if ,q
                        ,r
                        ,s)))
               defn)
           (evalo `(begin
                     ,defn
                     (list
                      (append '() '())
                      (append '(,g1) '(,g2))
                      (append '(,g3 ,g4 ,g5) '(,g6 ,g7))))
                  (list '() `(,g1 ,g2) `(,g3 ,g4 ,g5 ,g6 ,g7)))))))
   '(((define append (lambda (l s) (if (null? l) s (cons (car l) (append (cdr l) s)))))))))

(time
 (test 'append-hard-13-gensym
   (run 1 (defn)
     (let ((g1 (gensym "g1"))
           (g2 (gensym "g2"))
           (g3 (gensym "g3"))
           (g4 (gensym "g4"))
           (g5 (gensym "g5"))
           (g6 (gensym "g6"))
           (g7 (gensym "g7")))
       (fresh ()
         (absento g1 defn)
         (absento g2 defn)
         (absento g3 defn)
         (absento g4 defn)
         (absento g5 defn)
         (absento g6 defn)
         (absento g7 defn)
         (fresh (q)
           (== `(define append
                  (lambda (l s) ,q))
               defn)
           (evalo `(begin
                     ,defn
                     (list
                      (append '() '())
                      (append '(,g1) '(,g2))
                      (append '(,g3 ,g4 ,g5) '(,g6 ,g7))))
                  (list '() `(,g1 ,g2) `(,g3 ,g4 ,g5 ,g6 ,g7)))))))
   '(((define append (lambda (l s) (if (null? l) s (cons (car l) (append (cdr l) s)))))))))

; append-hard-15-gensym seems just as good, so don't waste time on this test case by default
;(time
 ;(test 'append-hard-14-gensym
   ;(run 1 (defn)
     ;(let ((g1 (gensym "g1"))
           ;(g2 (gensym "g2"))
           ;(g3 (gensym "g3"))
           ;(g4 (gensym "g4"))
           ;(g5 (gensym "g5"))
           ;(g6 (gensym "g6"))
           ;(g7 (gensym "g7")))
       ;(fresh ()
         ;(absento g1 defn)
         ;(absento g2 defn)
         ;(absento g3 defn)
         ;(absento g4 defn)
         ;(absento g5 defn)
         ;(absento g6 defn)
         ;(absento g7 defn)
         ;(fresh (p q r)
           ;(== `(define ,p
                  ;(lambda ,q ,r))
               ;defn)
           ;(evalo `(begin
                     ;,defn
                     ;(list
                      ;(append '() '())
                      ;(append '(,g1) '(,g2))
                      ;(append '(,g3 ,g4 ,g5) '(,g6 ,g7))))
                  ;(list '() `(,g1 ,g2) `(,g3 ,g4 ,g5 ,g6 ,g7)))))))
   ;'(((define append (lambda (_.0 _.1) (if (null? _.0) _.1 (cons (car _.0) (append (cdr _.0) _.1))))) (sym _.0 _.1)))))

; this one seems just as fast as append-hard-14-gensym
(time
 (test 'append-hard-15-gensym
   (run 1 (defn)
     (let ((g1 (gensym "g1"))
           (g2 (gensym "g2"))
           (g3 (gensym "g3"))
           (g4 (gensym "g4"))
           (g5 (gensym "g5"))
           (g6 (gensym "g6"))
           (g7 (gensym "g7")))
       (fresh ()
         (absento g1 defn)
         (absento g2 defn)
         (absento g3 defn)
         (absento g4 defn)
         (absento g5 defn)
         (absento g6 defn)
         (absento g7 defn)
         (evalo `(begin
                   ,defn
                   (list
                     (append '() '())
                     (append '(,g1) '(,g2))
                     (append '(,g3 ,g4 ,g5) '(,g6 ,g7))))
                (list '() `(,g1 ,g2) `(,g3 ,g4 ,g5 ,g6 ,g7))))))
   '(((define append
        (lambda (_.0 _.1)
          (if (null? _.0)
            _.1
            (cons (car _.0)
                  (append (cdr _.0) _.1)))))
      (sym _.0 _.1)))))

(time (test 'reverse-1
  (run 1 (q r s)
    (evalo `(begin
              (define append
                (lambda (l s)
                  (if (null? l) s
                    (cons (car l)
                          (append (cdr l) s)))))
              (begin
                (define reverse
                  (lambda (xs)
                    (if (null? xs) '()
                      (,q (reverse ,r) ,s))))
                (list
                  (reverse '())
                  (reverse '(a))
                  (reverse '(foo bar))
                  (reverse '(1 2 3)))))
          (list '() '(a) '(bar foo) '(3 2 1))))
  '(((append (cdr xs) (list (car xs)))))))

(time (test 'reverse-2
  (run 1 (defn)
    (let ((g1 (gensym "g1"))
          (g2 (gensym "g2"))
          (g3 (gensym "g3"))
          (g4 (gensym "g4"))
          (g5 (gensym "g5"))
          (g6 (gensym "g6"))
          (g7 (gensym "g7")))
      (fresh (q r s)
        (absento g1 defn)
        (absento g2 defn)
        (absento g3 defn)
        (absento g4 defn)
        (absento g5 defn)
        (absento g6 defn)
        (absento g7 defn)
        (== `(define reverse
               (lambda (xs)
                 (if (null? xs)
                   '()
                   (,q (reverse ,r) ,s))))
            defn)
        (evalo `(begin
                  (define append
                    (lambda (l s)
                      (if (null? l) s
                        (cons (car l)
                              (append (cdr l) s)))))
                  (begin
                    ,defn
                    (list
                      (reverse '())
                      (reverse '(,g1))
                      (reverse '(,g2 ,g3))
                      (reverse '(,g4 ,g5 ,g6)))))
               (list '() `(,g1) `(,g3 ,g2) `(,g6 ,g5 ,g4))))))
  '(((define reverse
       (lambda (xs)
         (if (null? xs)
           '()
           (append (reverse (cdr xs))
                   (list (car xs))))))))))

;(time (test 'reverse-3
  ;(run 1 (defn)
    ;(let ((g1 (gensym "g1"))
          ;(g2 (gensym "g2"))
          ;(g3 (gensym "g3"))
          ;(g4 (gensym "g4"))
          ;(g5 (gensym "g5"))
          ;(g6 (gensym "g6"))
          ;(g7 (gensym "g7")))
      ;(fresh (q r s)
        ;(absento g1 defn)
        ;(absento g2 defn)
        ;(absento g3 defn)
        ;(absento g4 defn)
        ;(absento g5 defn)
        ;(absento g6 defn)
        ;(absento g7 defn)
        ;(== `(define reverse
               ;(lambda (xs)
                 ;(if (null? xs)
                   ;'()
                   ;(append (,q ,r) ,s))))
            ;defn)
        ;(evalo `(begin
                  ;(define append
                    ;(lambda (l s)
                      ;(if (null? l) s
                        ;(cons (car l)
                              ;(append (cdr l) s)))))
                  ;(begin
                    ;,defn
                    ;(list
                      ;(reverse '())
                      ;(reverse '(,g1))
                      ;(reverse '(,g2 ,g3))
                      ;(reverse '(,g4 ,g5 ,g6)))))
               ;(list '() `(,g1) `(,g3 ,g2) `(,g6 ,g5 ,g4))))))
  ;'(((define reverse
       ;(lambda (xs)
         ;(if (null? xs)
           ;'()
           ;(append (reverse (cdr xs))
                   ;(list (car xs))))))))))

;(time (test 'reverse-4
  ;(run 1 (defn)
    ;(let ((g1 (gensym "g1"))
          ;(g2 (gensym "g2"))
          ;(g3 (gensym "g3"))
          ;(g4 (gensym "g4"))
          ;(g5 (gensym "g5"))
          ;(g6 (gensym "g6"))
          ;(g7 (gensym "g7")))
      ;(fresh (q r)
        ;(absento g1 defn)
        ;(absento g2 defn)
        ;(absento g3 defn)
        ;(absento g4 defn)
        ;(absento g5 defn)
        ;(absento g6 defn)
        ;(absento g7 defn)
        ;(== `(define reverse
               ;(lambda (xs)
                 ;(if (null? xs)
                   ;'()
                   ;(append ,q ,r))))
            ;defn)
        ;(evalo `(begin
                  ;(define append
                    ;(lambda (l s)
                      ;(if (null? l) s
                        ;(cons (car l)
                              ;(append (cdr l) s)))))
                  ;(begin
                    ;,defn
                    ;(list
                      ;(reverse '())
                      ;(reverse '(,g1))
                      ;(reverse '(,g2 ,g3))
                      ;(reverse '(,g4 ,g5 ,g6)))))
               ;(list '() `(,g1) `(,g3 ,g2) `(,g6 ,g5 ,g4))))))
  ;'(((define reverse
       ;(lambda (xs)
         ;(if (null? xs)
           ;'()
           ;(append (reverse (cdr xs))
                   ;(list (car xs))))))))))

;(time (test 'reverse-5
  ;(run 1 (defn)
    ;(let ((g1 (gensym "g1"))
          ;(g2 (gensym "g2"))
          ;(g3 (gensym "g3"))
          ;(g4 (gensym "g4"))
          ;(g5 (gensym "g5"))
          ;(g6 (gensym "g6"))
          ;(g7 (gensym "g7")))
      ;(fresh (q)
        ;(absento g1 defn)
        ;(absento g2 defn)
        ;(absento g3 defn)
        ;(absento g4 defn)
        ;(absento g5 defn)
        ;(absento g6 defn)
        ;(absento g7 defn)
        ;(absento 'match defn)
        ;(== `(define reverse
               ;(lambda (xs)
                 ;(if (null? xs)
                   ;'()
                   ;,q)))
            ;defn)
        ;(evalo `(begin
                  ;(define append
                    ;(lambda (l s)
                      ;(if (null? l) s
                        ;(cons (car l)
                              ;(append (cdr l) s)))))
                  ;(begin
                    ;,defn
                    ;(list
                      ;(reverse '())
                      ;(reverse '(,g1))
                      ;(reverse '(,g2 ,g3))
                      ;(reverse '(,g4 ,g5 ,g6)))
                    ;)
                  ;)
               ;(list '() `(,g1) `(,g3 ,g2) `(,g6 ,g5 ,g4))))))
  ;'(((define reverse
       ;(lambda (xs)
         ;(if (null? xs)
           ;'()
           ;(append (reverse (cdr xs))
                   ;(list (car xs))))))))))

;(time (test 'reverse-6
  ;(run 1 (defn)
    ;(let ((g1 (gensym "g1"))
          ;(g2 (gensym "g2"))
          ;(g3 (gensym "g3"))
          ;(g4 (gensym "g4"))
          ;(g5 (gensym "g5"))
          ;(g6 (gensym "g6"))
          ;(g7 (gensym "g7")))
      ;(fresh (q r s)
        ;(absento g1 defn)
        ;(absento g2 defn)
        ;(absento g3 defn)
        ;(absento g4 defn)
        ;(absento g5 defn)
        ;(absento g6 defn)
        ;(absento g7 defn)
        ;(== `(define reverse
               ;(lambda (xs)
                 ;(if ,q ,r ,s)))
            ;defn)
        ;(evalo `(begin
                  ;(define foldl
                    ;(lambda (f acc xs)
                      ;(if (null? xs)
                        ;acc
                        ;(foldl f (f (car xs) acc) (cdr xs)))))
                  ;(begin
                    ;,defn
                    ;(list
                      ;(reverse '())
                      ;(reverse '(,g1))
                      ;(reverse '(,g2 ,g3))
                      ;(reverse '(,g4 ,g5 ,g6)))))
               ;(list '() `(,g1) `(,g3 ,g2) `(,g6 ,g5 ,g4))))))
  ;'(((define reverse
       ;(lambda (xs)
         ;(if (null? xs)
           ;xs
           ;(foldl cons '() xs))))))))

(time (test 'reverse-7
  (run 1 (defn)
    (let ((g1 (gensym "g1"))
          (g2 (gensym "g2"))
          (g3 (gensym "g3"))
          (g4 (gensym "g4"))
          (g5 (gensym "g5"))
          (g6 (gensym "g6"))
          (g7 (gensym "g7")))
      (fresh (q r s)
        (absento g1 defn)
        (absento g2 defn)
        (absento g3 defn)
        (absento g4 defn)
        (absento g5 defn)
        (absento g6 defn)
        (absento g7 defn)
        (== `(define reverse
               (lambda (xs) ,q))
            defn)
        (evalo `(begin
                  (define foldl
                    (lambda (f acc xs)
                      (if (null? xs)
                        acc
                        (foldl f (f (car xs) acc) (cdr xs)))))
                  (begin
                    ,defn
                    (list
                      (reverse '())
                      (reverse '(,g1))
                      (reverse '(,g2 ,g3))
                      (reverse '(,g4 ,g5 ,g6)))))
               (list '() `(,g1) `(,g3 ,g2) `(,g6 ,g5 ,g4))))))
  '(((define reverse
       (lambda (xs)
         (if (null? xs)
           xs
           (foldl cons '() xs))))))))

;(time (test 'reverse-8
  ;(run 1 (defn)
    ;(let ((g1 (gensym "g1"))
          ;(g2 (gensym "g2"))
          ;(g3 (gensym "g3"))
          ;(g4 (gensym "g4"))
          ;(g5 (gensym "g5"))
          ;(g6 (gensym "g6"))
          ;(g7 (gensym "g7")))
      ;(fresh ()
        ;(absento g1 defn)
        ;(absento g2 defn)
        ;(absento g3 defn)
        ;(absento g4 defn)
        ;(absento g5 defn)
        ;(absento g6 defn)
        ;(absento g7 defn)
        ;(evalo `(begin
                  ;(define foldl
                    ;(lambda (f acc xs)
                      ;(if (null? xs)
                        ;acc
                        ;(foldl f (f (car xs) acc) (cdr xs)))))
                  ;(begin
                    ;,defn
                    ;(list
                      ;(reverse '())
                      ;(reverse '(,g1))
                      ;(reverse '(,g2 ,g3))
                      ;(reverse '(,g4 ,g5 ,g6)))))
               ;(list '() `(,g1) `(,g3 ,g2) `(,g6 ,g5 ,g4))))))
  ;'(((define reverse
       ;(lambda (xs)
         ;(if (null? xs)
           ;xs
           ;(foldl cons '() xs))))))))

(time (test 'rev-tailcall-1
  (run 1 (defn)
    (let ((g1 (gensym "g1"))
          (g2 (gensym "g2"))
          (g3 (gensym "g3"))
          (g4 (gensym "g4"))
          (g5 (gensym "g5"))
          (g6 (gensym "g6"))
          (g7 (gensym "g7")))
      (fresh (q r s)
        (absento g1 defn)
        (absento g2 defn)
        (absento g3 defn)
        (absento g4 defn)
        (absento g5 defn)
        (absento g6 defn)
        (absento g7 defn)
        (evalo `(begin
                  ,defn
                  (list
                    (rev-tailcall '() ',g7)
                    (rev-tailcall '(,g1) ',g7)
                    (rev-tailcall '(,g2 ,g3) ',g7)
                    (rev-tailcall '(,g4 ,g5 ,g6) ',g7)))
               (list g7 `(,g1 . ,g7) `(,g3 ,g2 . ,g7) `(,g6 ,g5 ,g4 . ,g7))))))
  '(((define rev-tailcall
       (lambda (_.0 _.1)
         (if (null? _.0)
           _.1
           (rev-tailcall (cdr _.0) (cons (car _.0) _.1)))))
     (sym _.0 _.1)))))
