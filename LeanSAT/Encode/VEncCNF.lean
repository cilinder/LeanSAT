/-
Copyright (c) 2024 The LeanSAT Contributors.
Released under the Apache License v2.0; see LICENSE for full text.

Authors: James Gallicchio
-/

import LeanSAT.Encode.EncCNF
import Mathlib.Tactic.LiftLets

/-! ## Verified Encodings

This file defines `VEncCNF`,
the main type for building *verified* encodings to CNF.
This augments the regular `EncCNF` with the ability to specify
and verify what a particular `EncCNF` value actually encodes.
-/

namespace LeanSAT.Encode

open Model PropFun EncCNF

namespace EncCNF

variable [LitVar L ν]

/-- `e` encodes proposition `P` -/
def encodesProp (e : EncCNF L α) (P : PropAssignment ν → Prop) : Prop :=
  aux e.1
where aux (e' : StateM _ α) :=
  ∀ s,
    let s' := (e' s).2
    s'.vMap = s.vMap ∧
    s'.assumeVars = s.assumeVars ∧
    -- TODO(JG): should we weaken this to equisatisfiability?
    ∀ τ, s'.interp τ ↔ s.interp τ ∧ (¬(τ ⊨ ↑s.assumeVars) → P τ)

open PropFun in
/-- If `e` encodes `P`, then `P` is satisfiable iff `e.toICnf` is satisfiable -/
theorem encodesProp_equisatisfiable [FinEnum ν] (e : EncCNF L α) (P : PropAssignment ν → Prop) (h : encodesProp e P)
  : (∃ τ : PropAssignment ν, P τ) ↔ (∃ τ : PropAssignment IVar, τ ⊨ e.toICnf.toPropFun) := by
  simp [toICnf, run, StateT.run]
  generalize hls : LawfulState.new' _ _ = ls
  have := h ls
  generalize hls' : e.1 ls = ls' at this
  rcases ls' with ⟨a,ls'⟩
  simp only at this ⊢
  rcases this with ⟨-,-,h3⟩
  rw [←hls] at h3
  simp [LawfulState.new', State.new, Clause.toPropFun, any] at h3
  clear hls' hls
  simp_rw [← h3]
  simp [LawfulState.interp]
  aesop

attribute [aesop unsafe apply] le_trans

theorem bind_encodesProp (e1 : EncCNF L α) (f : α → EncCNF L β)
  : e1.encodesProp P → (∀ s, (f (e1.1 s).1).encodesProp Q) →
    (e1 >>= f).encodesProp (P ⊓ Q)
  := by
  intro hP hQ s
  simp [encodesProp, encodesProp.aux] at hP hQ
  -- specialize hypotheses to the first state `s`
  rcases e1 with ⟨e1,he1⟩
  replace hP := hP s
  replace hQ := hQ s
  simp [Bind.bind, StateT.bind] at hP hQ ⊢
  replace he1 := he1 s
  -- give name to the next state `s'`
  generalize hs' : e1 s = s' at *
  rcases s' with ⟨a,s'⟩
  simp at *
  -- give name to the next state machine
  generalize he2 : (f a) = e2 at *
  rcases e2 with ⟨e2,he2⟩
  -- specialize hypotheses to this state `s'`
  replace hQ := hQ s'
  simp at *
  -- give name to the next state `s''`
  generalize hs'' : e2 s' = s'' at *
  rcases s'' with ⟨b,s''⟩
  simp at hQ ⊢
  -- once again we ♥ aesop
  aesop

@[simp] theorem encodesProp_pure (a : α) : encodesProp (pure a : EncCNF L α) (fun _ => True) := by
  intro s; simp [Pure.pure, StateT.pure]

end EncCNF

/-- The verified encoding monad. -/
def VEncCNF (L) [LitVar L ν] (α : Type u) (P : PropAssignment ν → Prop) :=
  { e : EncCNF L α // e.encodesProp P }

namespace VEncCNF

variable {L} [LitVar L ν]

instance : CoeHead (VEncCNF L α P) (EncCNF L α) := ⟨(·.1)⟩

theorem toICnf_equisatisfiable [FinEnum ν] (v : VEncCNF L α P) :
    (∃ τ : PropAssignment _, τ ⊨ v.val.toICnf.toPropFun) ↔
      ∃ τ : PropAssignment ν, P τ
  := by
  rw [v.val.encodesProp_equisatisfiable _ v.property]

def mapProp {P P' : PropAssignment ν → Prop} (h : P = P') : VEncCNF L α P → VEncCNF L α P' :=
  fun ⟨e,he⟩ => ⟨e, h ▸ he⟩

def newCtx (name : String) (inner : VEncCNF L α P) : VEncCNF L α P :=
  ⟨EncCNF.newCtx name inner, inner.2⟩

protected def pure (a : α) : VEncCNF L α (fun _ => True) := ⟨Pure.pure a, by
    intro s; simp [Pure.pure, StateT.pure]⟩

def addClause [DecidableEq ν] (C : Clause L) : VEncCNF L Unit (· ⊨ ↑C) :=
  ⟨EncCNF.addClause C, by
    intro s
    generalize he : (EncCNF.addClause C).1 s = e
    rcases e with ⟨_,s'⟩
    simp [EncCNF.addClause] at he; cases he
    simp; simp [LawfulState.addClause, State.addClause]
    ⟩

/-- runs `e`, adding `ls` to each generated clause -/
def unlessOneOf [LawfulLitVar L ν] (ls : Array L) (ve : VEncCNF L α P)
    : VEncCNF L α (fun τ => (∀ l ∈ ls, τ ⊭ ↑l) → P τ) :=
  ⟨EncCNF.unlessOneOf ls ve, by
    -- TODO: terrible, slow proof
    intro s
    rcases ve with ⟨ve,hve⟩
    simp only [StateT.run] at hve ⊢
    generalize he : (EncCNF.unlessOneOf ls ve).1 s = e
    rcases e with ⟨a,s'⟩; dsimp
    simp only [EncCNF.unlessOneOf] at he
    generalize hsprev : EncCNF.LawfulState.mk .. = sprev at he
    generalize he' : ve.1 sprev = e
    rcases e with ⟨a',s''⟩
    have := hve sprev
    clear hve
    simp only [he'] at he this
    clear he'
    cases he; cases hsprev
    simp at this ⊢
    rcases s'' with ⟨⟨s''a,s''b,s''c⟩,s''d,s''e,s''f⟩
    rcases s with ⟨⟨sa,sb,sc⟩,sd,se,sf⟩
    simp
    cases this
    subst_vars
    simp only [EncCNF.LawfulState.interp] at *
    simp_all
    clear! s''f s''e s''d sf se sd
    rintro _ _ rfl
    simp [Clause.satisfies_iff, not_or]
  ⟩

def assuming [LawfulLitVar L ν] (ls : Array L) (e : VEncCNF L α P)
    : VEncCNF L α (fun τ => (∀ l ∈ ls, τ ⊨ ↑l) → P τ) :=
  unlessOneOf (ls.map (- ·)) e |>.mapProp (by
    ext τ
    simp [Clause.satisfies_iff, Array.mem_def]
  )

set_option pp.proofs.withType false in
@[inline]
def withTemps [LawfulLitVar L ν] [DecidableEq ν] (n) {P : PropAssignment (ν ⊕ Fin n) → Prop}
    (ve : VEncCNF (WithTemps L n) α P) :
    VEncCNF L α (fun τ => ∃ σ, τ = σ.map Sum.inl ∧ P σ) :=
  ⟨EncCNF.withTemps _ ve.1, by
    intro ls_pre ls_post'
    -- give various expressions names and specialize hypotheses
    have def_ls_post : ls_post' = Prod.snd _ := rfl
    generalize ls_post' = ls_post at *; clear ls_post'
    generalize def_ls_post_pair : (EncCNF.withTemps n ve.1).1 ls_pre = ls_post_pair
      at def_ls_post
    unfold EncCNF.withTemps at def_ls_post_pair
    simp (config := {zeta := false}) at def_ls_post_pair
    lift_lets at def_ls_post_pair
    extract_lets vMap vMapInj assumeVars at def_ls_post_pair
    split at def_ls_post_pair
    next a ls_post_temps def_pair =>
    generalize_proofs h
    subst def_ls_post_pair
    simp at def_ls_post; clear vMap assumeVars
    generalize def_ls_pre_temps : LawfulState.withTemps ls_pre = ls_pre_temps
    rw [def_ls_pre_temps] at def_pair
    -- extract relationship between ls_pre_temps and ls_post_temps
    have ls_temps_nextVar := ve.1.2 ls_pre_temps
    simp [def_pair] at ls_temps_nextVar
    have ls_temps_satisfies := ve.2 ls_pre_temps
    simp [def_pair] at ls_temps_satisfies
    clear def_pair
    rcases ls_temps_satisfies with ⟨hvmap, hassume, h⟩
    -- now we prove the goals
    subst ls_post
    simp
    rw [LawfulState.interp_withoutTemps]
    · simp_rw [h]
      subst ls_pre_temps
      simp
      clear h hassume hvmap ls_temps_nextVar def_pair ls_post_temps vMapInj
      intro τ
      constructor
      · aesop
      · rintro ⟨h1,h2⟩
        rcases (inferInstance : Decidable (τ ⊨ ls_pre.assumeVars.toPropFun)) with h | h
        . rcases h2 h with ⟨σ, rfl, _⟩
          use σ
          tauto
        . let σ : PropAssignment (ν ⊕ Fin n) := fun | .inl x => τ x | _ => false
          use σ
          have : τ = PropAssignment.map Sum.inl σ := funext fun x => by simp only [PropAssignment.get_map]
          tauto
    · aesop
  ⟩

protected def bind (e1 : VEncCNF L α P) (e2 : α → VEncCNF L β Q) : VEncCNF L β (P ⊓ Q) :=
  VEncCNF.mapProp (show P ⊓ (Q ⊓ ⊤) = (P ⊓ Q) by simp)
    ⟨ do let a ← e1; return ← e2 a
    , by
      simp
      apply bind_encodesProp _ _ e1.2
      intro s
      exact (e2 (e1.1.1 s).1).2
    ⟩

/-- Sequences two encodings together, i.e. a conjunction of the encodings.

For sequencing many encodings together, see `seq[ ... ]` syntax
-/
def seq (e1 : VEncCNF L Unit P) (e2 : VEncCNF L β Q) : VEncCNF L β (fun τ => P τ ∧ Q τ) :=
  VEncCNF.bind e1 (fun () => e2)

scoped syntax "seq[ " term,+ " ]" : term

macro_rules
| `(seq[$as:term,*]) => do
  as.getElems.foldrM (β := Lean.TSyntax `term)
    (fun a acc => `(seq $a $acc))
    (← `(VEncCNF.pure ()))

@[inline]
def for_all (arr : Array α) {P : α → PropAssignment ν → Prop} (f : (a : α) → VEncCNF L Unit (P a))
  : VEncCNF L Unit (fun τ => ∀ a ∈ arr, P a τ) :=
  ⟨ arr.foldlM (fun () x => f x) ()
  , by
    rcases arr with ⟨L⟩
    rw [Array.foldlM_eq_foldlM_data]
    simp [Array.mem_def]
    induction L with
    | nil   => simp
    | cons hd tl ih =>
      simp
      apply bind_encodesProp
      · have := (f hd).2
        simpa using this
      · aesop⟩

-- Cayden TODO: Unit could possibly made to be β instead? Generalize later.
-- One would think that P could be of type {P : PropFun ν}. But Lean timed out synthesizing that
def guard (p : Prop) [Decidable p] {P : p → PropAssignment ν → Prop}
      (f : (h : p) → VEncCNF L Unit (P h))
  : VEncCNF L Unit (if h : p then P h else fun _ => True) :=
  ⟨ do if h : p then f h
  , by
    by_cases h : p <;> simp [h]
    simpa using (f h).2⟩

def ite (p : Prop) [Decidable p] {P : p → PropAssignment ν → Prop} {Q : ¬p → PropAssignment ν → Prop}
    (f : (h : p) → VEncCNF L Unit (P h))
    (g : (h : ¬p) → VEncCNF L Unit (Q h))
  : VEncCNF L Unit (if h : p then P h else Q h) :=
  ⟨ if h : p then f h
             else g h
  , by
    by_cases h : p <;> simp [h]
    · simpa using (f h).2
    · simpa using (g h).2⟩

def andImplyOr [LawfulLitVar L ν] [DecidableEq ν] (hyps : Array L) (conc : Array L)
  : VEncCNF L Unit (fun τ => (∀ h ∈ hyps, τ ⊨ ↑h) → (∃ c ∈ conc, τ ⊨ ↑c)) :=
  addClause (hyps.map LitVar.negate ++ conc)
  |> mapProp (by
    ext τ
    simp [Clause.satisfies_iff]
    constructor
    · aesop
    · intro h
      by_cases h' : ∀ a ∈ hyps, τ ⊨ LitVar.toPropFun a
      · aesop
      · aesop)

def andImply [LawfulLitVar L ν] [DecidableEq ν] (hyps : Array L) (conc : L)
  : VEncCNF L Unit (fun τ => (∀ h ∈ hyps, τ ⊨ ↑h) → τ ⊨ ↑conc) :=
  andImplyOr hyps #[conc]
  |> mapProp (by simp [any])

def implyOr [LawfulLitVar L ν] [DecidableEq ν] (hyp : L) (conc : Array L)
  : VEncCNF L Unit (fun τ => τ ⊨ ↑hyp → ∃ c ∈ conc, τ ⊨ ↑c) :=
  andImplyOr #[hyp] conc
  |> mapProp (by simp [all])

def orImplyOr [LawfulLitVar L ν] [DecidableEq ν] (hyps : Array L) (conc : Array L)
  : VEncCNF L Unit (fun τ => (∃ h ∈ hyps, τ ⊨ ↑h) → (∃ c ∈ conc, τ ⊨ ↑c)) :=
  for_all hyps (fun hyp => andImplyOr #[hyp] conc)
  |> mapProp (by
    ext τ
    simp [-List.mapM,Clause.satisfies_iff]
  )

def orImply [LawfulLitVar L ν] [DecidableEq ν] (hyps : Array L) (conc : L)
  : VEncCNF L Unit (fun τ => (∃ h ∈ hyps, τ ⊨ ↑h) → τ ⊨ ↑conc) :=
  orImplyOr hyps #[conc]
  |> mapProp (by simp [any])

def andImplyAnd [LawfulLitVar L ν] [DecidableEq ν] (hyps : Array L) (concs : Array L)
  : VEncCNF L Unit (fun τ => (∀ h ∈ hyps, τ ⊨ ↑h) → (∀ c ∈ concs, τ ⊨ ↑c)) :=
  for_all concs (fun conc => andImplyOr hyps #[conc])
  |> mapProp (by
    ext τ
    simp [Clause.satisfies_iff]
    aesop
  )

def implyAnd [LawfulLitVar L ν] [DecidableEq ν] (hyp : L) (concs : Array L)
  : VEncCNF L Unit (fun τ => τ ⊨ ↑hyp → (∀ c ∈ concs, τ ⊨ ↑c)) :=
  andImplyAnd #[hyp] concs
  |> mapProp (by simp [all])

def orImplyAnd [LawfulLitVar L ν] [DecidableEq ν] (hyps : Array L) (concs : Array L)
  : VEncCNF L Unit (fun τ => (∃ h ∈ hyps, τ ⊨ ↑h) → (∀ c ∈ concs, τ ⊨ ↑c)) :=
  for_all hyps (fun hyp =>
    for_all concs (fun conc =>
      andImplyOr #[hyp] #[conc]
    )
  )
  |> mapProp (by
    ext τ
    simp [Clause.satisfies_iff]
    aesop
  )

def imply [LawfulLitVar L ν] [DecidableEq ν] (v1 v2 : L)
  : VEncCNF L Unit (· ⊨ ↑v1 ⇨ ↑v2) :=
  andImplyOr #[v1] #[v2]
  |> mapProp (by simp [all,any])

def biImpl [LawfulLitVar L ν] [DecidableEq ν] (v1 v2 : L)
  : VEncCNF L Unit (fun τ => τ ⊨ ↑v1 ↔ τ ⊨ ↑v2) :=
  seq (imply v1 v2) (imply v2 v1)
  |> mapProp (by aesop)

def defConj [LawfulLitVar L ν] [DecidableEq ν] (v : L) (vs : Array L)
  : VEncCNF L Unit (fun τ => τ ⊨ ↑v ↔ (∀ v ∈ vs, τ ⊨ ↑v)) :=
  seq (implyAnd v vs) (andImply vs v)
  |> mapProp (by aesop)

def defDisj [LawfulLitVar L ν] [DecidableEq ν] (v : L) (vs : Array L)
  : VEncCNF L Unit (fun τ => τ ⊨ ↑v ↔ (∃ v ∈ vs, τ ⊨ ↑v)) :=
  seq (implyOr v vs) (orImply vs v)
  |> mapProp (by aesop)
