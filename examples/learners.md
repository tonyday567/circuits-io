# learners ⟜ free compact closed via quotiented learners

Riley (ACT 2024). The category of extensional learners, quotiented to force
the snake equations, is the free compact closed category on a symmetric
monoidal category. This is the dual counterpart to Circuit (free traced
monoidal). Compact closed = traced + duals.

## the result

**Theorem 3.3.** `AtempC` (atemporal learners) is the free compact closed
category on a symmetric monoidal category C.

The construction: extensional learners `LearnC` have an obvious involution
`(A,A')* = (A',A)` giving cups and caps. The snake equations fail. Quotient
by the snake diagrams → `AtempC` → compact closed.

## a learner

An extensional learner `(A,A') → (B,B')` is an element of the coend:

```
LearnC((A,A'),(B,B')) = ∫^{P,Q:C} C(P⊗A, Q⊗B) × C(Q⊗B', P⊗A')
```

Written as `(f | g)` where `f : P⊗A → Q⊗B` (forward) and `g : Q⊗B' → P⊗A'`
(backward). The parameter objects `P,Q` are existentially quantified.

Compare with optics: `Optic((A,A'),(B,B')) = ∫^{M:C} C(A, M⊗B) × C(M⊗B', A')`.
A learner has parameters on both sides, optics on one.

## duality for free

The involution is trivial: swap the two components.

```
(A,A')* := (A',A)
(L | R)* := (R | L)
```

This is a strict symmetric monoidal functor `LearnC → LearnC^op`. Cups and
caps follow immediately:

```
η : (I,I) → (A,A') ⊗ (A,A')*       -- cup
ε : (A,A')* ⊗ (A,A') → (I,I)       -- cap
```

## the snake equations fail

The composite `(A,I) → (A,I) ⊗ ((A,I)* ⊗ (A,I)) → ... → (A,I)` is not the
identity. It's a learner that "runs one training datum behind" — it updates
the parameter with a remembered pair before producing output. Under
extensional equivalence this is not equal to the identity.

## quotient → compact closed

`AtempC` forces the snake diagrams to equal the identity. After the quotient:
- Cups and caps become proper duals
- Extranaturality holds for all morphisms
- The category is compact closed
- It's the *free* one on C

## connection to Circuit

```
                     free traced monoidal
  Circuit ─────────────────────────────────────►
                                                  compact closed
  Learners ────────────────────────────────────► = traced + duals
                     free compact closed
```

Circuit gives the trace. Learners give the duals. The quotient that makes
learners compact closed is exactly the move from `LearnC` (almost compact
closed) to `AtempC` (compact closed proper). The snake equations are the
missing piece — same equations that separate a traced monoidal category
with duals from a compact closed one.

## what this means for circuits

To get compact closed from Circuit: add `Dual` to the GADT, implement cups
and caps, force the snake equations. That's the program sketched in
`examples/pipes.md` (the `Back` GADT with `Dual` constructor) and
`other/07-future.md` (learner integration).

The learners paper says: quotient by snake equations. The same quotient would
turn `Circuit + Dual` into a compact closed category. The learner dual
`(A,A')* = (A',A)` is the same structural move as `Dual :: Back arr t a b ->
Back arr t b a` — flip the direction.

## reference

- Mitchell Riley, "Learners are Almost Free Compact Closed", ACT 2024
  (EPTCS 429, 2025, pp. 49–62). arXiv:2509.20930
- `other/07-future.md` — the program for learner integration in circuits
- `examples/pipes.md` — the `Back` GADT with `Dual` constructor
- Fong, Spivak, Tuyéras, "Backprop as Functor" (2019) — original learners paper
