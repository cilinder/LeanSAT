/-
Copyright (c) 2024 The LeanSAT Contributors.
Released under the Apache License v2.0; see LICENSE for full text.

Authors: James Gallicchio
-/

import Std
import LeanSAT.Data.Cnf
import LeanSAT.Data.ICnf
import LeanSAT.Data.Literal
import LeanSAT.Data.HashAssn
import LeanSAT.Upstream.ToStd
import LeanSAT.Model.Quantifiers
import LeanSAT.Upstream.FinEnum

open Std

namespace LeanSAT.Encode

open Model

namespace EncCNF

/-- State for an encoding.

We need to parameterize by literal type `L` (and variable `ν`),
because otherwise we need to prove everywhere that clauses are "within range"
-/
@[ext]
structure State (L ν : Type u) where
  nextVar : PNat
  cnf : ICnf
  vMap : ν → IVar
  /-- assume `¬assumeVars` in each new clause -/
  assumeVars : Clause L

namespace State

variable [LitVar L ν]

def new (vars : PNat) (f : ν → IVar) : State L ν := {
  nextVar := vars
  cnf := #[]
  vMap := f
  assumeVars := #[]
}

def addClause (C : Clause L) : State L ν → State L ν
| {nextVar, cnf, vMap, assumeVars} => {
  nextVar := nextVar
  vMap := vMap
  assumeVars := assumeVars
  cnf := cnf.addClause ((Clause.or assumeVars C).map _ vMap)
}

@[simp] theorem toPropFun_addClause (C : Clause L) (s)
  : (addClause C s).cnf.toPropFun = s.cnf.toPropFun ⊓ PropFun.map s.vMap (s.assumeVarsᶜ ⇨ C)
  := by
  simp [addClause, BooleanAlgebra.himp_eq, sup_comm]

instance : ToString (State L ν) := ⟨toString ∘ State.cnf⟩

end State

/-- Lawfulness conditions on encoding state. -/
@[ext]
structure LawfulState (L ν) extends State L ν where
  cnfVarsLt : ∀ c ∈ cnf, ∀ l ∈ c, (LitVar.toVar l) < nextVar
  vMapLt : ∀ v, vMap v < nextVar
  vMapInj : vMap.Injective

namespace LawfulState

instance : Coe (LawfulState L ν) (State L ν) := ⟨LawfulState.toState⟩

theorem semVars_toPropFun_cnf_lt (s : LawfulState L ν)
  : ∀ v ∈ s.cnf.toPropFun.semVars, v < s.nextVar := by
  intro v h
  replace h := Cnf.mem_semVars_toPropFun _ _ h
  rcases h with ⟨C,hC,h⟩
  replace h := Clause.mem_semVars_toPropFun _ _ h
  rcases h with ⟨l,hl,rfl⟩
  apply s.cnfVarsLt _ hC _ hl


variable [LitVar L ν]

open PropFun in
/-- The interpretation of an `EncCNF` state is the
formula's interpretation, but with all temporaries
existentially quantified away.
-/
noncomputable def interp (s : LawfulState L ν) : PropAssignment ν → Prop :=
  fun τ => ∃ σ, τ = PropAssignment.map s.vMap σ ∧ σ ⊨ s.cnf.toPropFun

def new (vars : PNat) (f : ν ↪ IVar) (h : ∀ v, f v < vars)
    : LawfulState L ν := {
  State.new vars f with
  cnfVarsLt := by intro c hc _ _; simp [State.new, Array.mem_def] at hc
  vMapLt := h
  vMapInj := f.injective
}

@[simp]
theorem interp_new (vars) (f : ν ↪ IVar) (h)
  : interp (new (L := L) vars f h) = fun _ => True := by
  ext τ
  simp [new, State.new, interp, Cnf.toPropFun, PropAssignment.map_eq_map]
  apply τ.exists_preimage

@[simp]
theorem toState_new (vars) (f : ν ↪ IVar) (h)
  : (new (L := L) vars f h).toState = State.new vars f := rfl

def new' (vars : Nat) (f : ν ↪ Fin vars) : LawfulState L ν :=
  new (Nat.succPNat vars)
    ⟨ fun v => Nat.succPNat (f v)
    , by intro x y; simp [State.new, ← PNat.val_eq_val, Fin.val_inj]⟩
    (by
      intro v; simp [State.new, Nat.succPNat]
      rw [PNat.mk_lt_mk, Nat.succ_lt_succ_iff]
      exact (f v).isLt)

@[simp]
theorem interp_new' (vars) (f : ν ↪ Fin vars)
  : interp (new' (L := L) vars f) = fun _ => True := by simp [new']

def addClause (C : Clause L) (s : LawfulState L ν) : LawfulState L ν where
  toState := s.toState.addClause C
  vMapLt := s.vMapLt
  vMapInj := s.vMapInj
  cnfVarsLt := by
    intro c hc v hv
    simp [State.addClause, Cnf.addClause, Clause.or, LitVar.map] at hc
    cases hc
    · apply cnfVarsLt; repeat assumption
    · subst_vars; simp [Clause.map] at hv
      rcases hv with ⟨a,_|_,rfl⟩
      · simp [LitVar.map]; apply vMapLt
      · simp [LitVar.map]; apply vMapLt

set_option pp.proofs.withType false in
open PropFun in
@[simp]
theorem interp_addClause
        (C : Clause L) (s : LawfulState L ν)
  : interp (addClause C s) = fun τ => interp s τ ∧ (τ ⊭ ↑s.assumeVars → τ ⊨ ↑C) := by
  ext τ
  simp [addClause, interp, State.addClause, imp_iff_not_or]
  rw [← exists_and_right]
  apply exists_congr; intro σ
  aesop

end LawfulState

end EncCNF

/-- Encoding monad.

This requires quite a few invariants to be held.
It receives and produces lawful states, and
never decreases the `nextVar`.
-/
def EncCNF (L) [LitVar L ν] (α) :=
  { sa : StateM (EncCNF.LawfulState L ν) α //
    ∀ s, s.nextVar ≤ (sa s).2.nextVar }

namespace EncCNF

variable {L} [LitVar L ν]

instance : Monad (EncCNF L) where
  pure a := ⟨pure a, by simp [pure, StateT.pure]⟩
  bind | ⟨sa,h⟩, f => ⟨bind sa (f · |>.1), by
    intro s
    simp [bind, StateT.bind]
    split
    next a s' hs' =>
    apply Nat.le_trans (m := s'.nextVar)
    · have := h s
      rw [hs'] at this
      exact this
    · exact (f a).2 s'
    ⟩

instance : LawfulMonad (EncCNF L) where
  map_const := by simp [Functor.mapConst, Functor.map]
  id_map := by intros; simp [Functor.map]; split; rfl
  seqLeft_eq := by
    intros; simp [Functor.map]; rfl
  seqRight_eq := by
    intros; simp [Functor.map]; rfl
  pure_seq := by
    intros; simp [Functor.map]; rfl
  bind_pure_comp := by
    intros; simp [Functor.map]; rfl
  bind_map := by
    intros; simp [Functor.map]; rfl
  pure_bind := by
    intros; simp [bind]; rfl
  bind_assoc := by
    intros; simp [bind]; rfl

def run [FinEnum ν] (e : EncCNF L α) : α × LawfulState L ν :=
  e.1.run <| LawfulState.new' (FinEnum.card ν) (FinEnum.equiv.toEmbedding)

def toICnf [FinEnum ν] (e : EncCNF L α) : ICnf := (run e).2.cnf

def newCtx (name : String) (inner : EncCNF L α) : EncCNF L α := do
  let res ← inner
  return res

def addClause (C : Clause L) : EncCNF L Unit :=
  ⟨ fun s =>
    ((), s.addClause C), by simp [LawfulState.addClause, State.addClause]⟩

/-- runs `e`, adding `ls` to each generated clause -/
def unlessOneOf (ls : Array L) (e : EncCNF L α) : EncCNF L α :=
  ⟨ fun state =>
    let oldAssumes := state.assumeVars
    let newState := { state with
      assumeVars := oldAssumes.or ls
    }
    let (res, newState) := e.1 newState
    (res, {newState with
      assumeVars := oldAssumes
    }),
    by intro s; simp; split; next a s' hs' =>
      simp; have := hs' ▸ e.2 _; simpa using this⟩

def assuming [LawfulLitVar L ν] (ls : Array L) (e : EncCNF L α) : EncCNF L α :=
  unlessOneOf (ls.map (- ·)) e

def blockAssn [BEq ν] [Hashable ν] (a : HashAssn L) : EncCNF L Unit :=
  addClause (a.toLitArray.map (- ·))

def addAssn [BEq ν] [Hashable ν] (a : HashAssn L) : EncCNF L Unit := do
  for l in a.toLitArray do
    addClause #[l]


/-! ### Temporaries -/

def WithTemps (L n) := L ⊕ Literal (Fin n)

instance : LitVar (WithTemps L n) (ν ⊕ Fin n) :=
  inferInstanceAs (LitVar (L ⊕ Literal (Fin n)) _)

instance [LawfulLitVar L ν] : LawfulLitVar (WithTemps L n) (ν ⊕ Fin n) :=
  inferInstanceAs (LawfulLitVar (L ⊕ Literal (Fin n)) _)

def WithTemps.var (l : L) : WithTemps L n := Sum.inl l
def WithTemps.temp (i : Fin n) : WithTemps L n := Sum.inr (LitVar.mkPos i)

@[simp] theorem WithTemps.toPropFun_var [LitVar L ν] (l : L)
  : LitVar.toPropFun (WithTemps.var (n := n) l) =
      (LitVar.toPropFun l).map Sum.inl := by
  simp [LitVar.toPropFun, var]
  split <;> simp_all [LitVar.polarity, LitVar.toVar]

@[simp] theorem WithTemps.toPropFun_temp [LitVar L ν] (i : Fin n)
  : LitVar.toPropFun (WithTemps.temp (L := L) i) =
      (PropFun.var i).map Sum.inr := by
  simp [LitVar.toPropFun, temp]
  rw [LitVar.polarity_inr,LitVar.toVar_inr,LawfulLitVar.toVar_mkPos]
  simp_all [LitVar.toVar]

@[simp] theorem WithTemps.toVar_var [LitVar L ν] (l : L)
  : LitVar.toVar (WithTemps.var (n := n) l) =
      Sum.inl (LitVar.toVar l) := by
  simp [LitVar.toVar, var]

@[simp] theorem WithTemps.toVar_temp [LitVar L ν] (i : Fin n)
  : LitVar.toVar (WithTemps.temp (L := L) i) =
      Sum.inr i := by
  rw [temp,LitVar.toVar_inr,LawfulLitVar.toVar_mkPos]

@[simp] theorem WithTemps.polarity_var [LitVar L ν] (l : L)
  : LitVar.polarity (WithTemps.var (n := n) l) =
      LitVar.polarity l := by
  simp [LitVar.polarity, var]

@[simp] theorem WithTemps.polarity_temp [LitVar L ν] (i : Fin n)
  : LitVar.polarity (WithTemps.temp (L := L) i) = true := by
  rw [temp, LitVar.polarity_inr, LawfulLitVar.polarity_mkPos]


def State.withTemps (s : State L ν) : State (WithTemps L n) (ν ⊕ Fin n) where
  nextVar := ⟨s.nextVar + n, by simp⟩
  cnf := s.cnf
  vMap := vMap
  assumeVars := s.assumeVars.map _ (Sum.inl ·)
where vMap (x) :=
  match x with
  | Sum.inl v => s.vMap v
  | Sum.inr i => ⟨s.nextVar + i, by simp⟩

@[simp] theorem State.cnf_withTemps (s : State L ν) :
    (State.withTemps s (n := n)).cnf = s.cnf
  := by simp [State.withTemps]

def LawfulState.withTemps (s : LawfulState L ν)
  : LawfulState (WithTemps L n) (ν ⊕ Fin n) where
  toState := s.toState.withTemps
  cnfVarsLt := by
    simp [State.withTemps]
    intro c hc l hl
    apply Nat.lt_of_lt_of_le
    · exact s.cnfVarsLt c hc l hl
    · simp; apply Nat.le_add_right
  vMapLt := by
    simp [State.withTemps]
    constructor
    · intro v; apply Nat.lt_of_lt_of_le
      · apply s.vMapLt
      · simp; apply Nat.le_add_right
    · intro a; apply (PNat.mk_lt_mk ..).mpr; simp
  vMapInj := by
    intro v1 v2
    simp [State.withTemps]
    cases v1 <;> cases v2 <;> simp
    · apply s.vMapInj
    · intro h; simp [State.withTemps.vMap] at h; have := h ▸ s.vMapLt _; simp [← PNat.coe_lt_coe] at this
    · intro h; simp [State.withTemps.vMap] at h; have := h.symm ▸ s.vMapLt _; simp [← PNat.coe_lt_coe] at this
    · simp [State.withTemps.vMap]; rw [Subtype.mk_eq_mk]
      intro h
      apply Fin.eq_of_veq; apply Nat.add_left_cancel h

@[simp] theorem LawfulState.vMap_withTemps (s : LawfulState L ν) :
    (s.withTemps (n := n)).vMap = State.withTemps.vMap s.toState
  := by simp [LawfulState.withTemps, State.withTemps]

@[simp] theorem LawfulState.assumeVars_withTemps (s : LawfulState L ν) :
    (s.withTemps (n := n)).assumeVars = s.assumeVars.map _ Sum.inl
  := by simp [LawfulState.withTemps, State.withTemps]

@[simp]
theorem LawfulState.interp_withTemps [DecidableEq ν]
          (s : LawfulState L ν) (n)
    : (s.withTemps (n := n)).interp = fun τ => s.interp (τ.map Sum.inl) := by
  ext τ
  simp [interp, withTemps, State.withTemps]
  constructor
  · rintro ⟨σ,rfl,h⟩
    use σ; simp [h]
    ext v; simp [State.withTemps.vMap]
  · rintro ⟨σ,h1,h2⟩
    have ⟨σ',hσ'⟩ := τ.exists_preimage ⟨State.withTemps.vMap s.toState, (LawfulState.withTemps s).vMapInj⟩
    cases hσ'
    simp [PropAssignment.map] at h2 ⊢
    use σ.setMany
      (Finset.univ.image (State.withTemps.vMap (n := n) s.toState <| Sum.inr ·))
      σ'
    constructor
    · ext vot
      rcases vot with (v|t)
      · have := congrFun h1 v
        simp at this; simp [this]; clear this h2
        simp [withTemps, State.withTemps, State.withTemps.vMap]
        rw [PropAssignment.setMany_not_mem]
        simp; intro x
        have := s.vMapLt v
        rw [←Subtype.val_inj]; rw [← PNat.coe_lt_coe] at this
        simp; apply Nat.ne_of_gt
        exact Nat.lt_add_right _ this
      · simp [State.withTemps.vMap]
    · apply (Model.PropFun.agreeOn_semVars _).mpr h2
      intro v hv
      simp at hv
      have := semVars_toPropFun_cnf_lt _ _ hv
      rw [PropAssignment.setMany_not_mem]
      simp [State.withTemps.vMap]
      intro v'
      rw [←Subtype.val_inj]; rw [← PNat.coe_lt_coe] at this
      simp; apply Nat.ne_of_gt
      exact Nat.lt_add_right _ this


def State.withoutTemps (vMap : ν → IVar) (assumeVars : Array L) (s : State (WithTemps L n) (ν ⊕ Fin n)) : State L ν where
  nextVar := s.nextVar
  cnf := s.cnf
  vMap := vMap
  assumeVars := assumeVars

@[simp] theorem State.vMap_withoutTemps (s : State _ _) :
    (State.withoutTemps (L := L) (ν := ν) (n := n) vm av s).vMap = vm
  := by simp [State.withoutTemps]

@[simp] theorem State.assumeVars_withoutTemps (s : State _ _) :
    (State.withoutTemps (L := L) (ν := ν) (n := n) vm av s).assumeVars = av
  := by simp [State.withoutTemps]

def LawfulState.withoutTemps (s : LawfulState (WithTemps L n) (ν ⊕ Fin n))
    (vMap : ν → IVar) (vMapLt : ∀ v, vMap v < s.nextVar) (vMapInj : vMap.Injective)
    (assumeVars : Array L)
    : LawfulState L ν where
  toState := s.toState.withoutTemps vMap assumeVars
  cnfVarsLt := by
    simp [State.withoutTemps]
    intro c hc l hl
    apply Nat.lt_of_lt_of_le
    · exact s.cnfVarsLt c hc l hl
    · simp
  vMapLt := by
    simp [State.withoutTemps]
    apply vMapLt
  vMapInj := by
    intro v1 v2
    simp [State.withoutTemps]
    apply vMapInj

@[simp] theorem LawfulState.vMap_withoutTemps (s : LawfulState (WithTemps L n) (ν ⊕ Fin n))
    {vMap : ν → IVar} {vMapLt : ∀ v, vMap v < s.nextVar} {vMapInj : vMap.Injective}
    : (LawfulState.withoutTemps s vMap vMapLt vMapInj av).vMap = vMap
  := by simp [LawfulState.withoutTemps]

@[simp] theorem LawfulState.assumeVars_withoutTemps (s : LawfulState (WithTemps L n) (ν ⊕ Fin n))
    {vMap : ν → IVar} {vMapLt : ∀ v, vMap v < s.nextVar} {vMapInj : vMap.Injective}
    : (LawfulState.withoutTemps s vMap vMapLt vMapInj av).assumeVars = av
  := by simp [LawfulState.withoutTemps]

theorem LawfulState.interp_withoutTemps [DecidableEq ν]
    (s : LawfulState (WithTemps L n) (ν ⊕ Fin n))
    {vMap : ν → IVar} {vMapLt : ∀ v, vMap v < s.nextVar} {vMapInj : vMap.Injective}
    (h : vMap = s.vMap ∘ Sum.inl)
    : LawfulState.interp (LawfulState.withoutTemps s vMap vMapLt vMapInj av) =
        fun τ => ∃ σ, τ = σ.map Sum.inl ∧ LawfulState.interp s σ
  := by
  ext τ
  cases h
  simp [LawfulState.withoutTemps, State.withoutTemps, interp]
  aesop

def nextVar_mono_of_eq {e : EncCNF L α} (h : e.1 s = (a, s')) :
    s.nextVar ≤ s'.nextVar := by
  have := h ▸ e.2 s
  exact this

def withTemps (n) (e : EncCNF (WithTemps L n) α) : EncCNF L α :=
  ⟨ fun s =>
    let vMap := s.vMap
    let vMapInj := s.vMapInj
    let assumeVars := s.assumeVars
    match h : e.1 s.withTemps with
    | (a,s') =>
    (a, s'.withoutTemps vMap (by
        intro v; simp; apply Nat.lt_of_lt_of_le (m := s.nextVar)
        · apply s.vMapLt
        · have := e.nextVar_mono_of_eq h
          apply Nat.le_trans (m := s.nextVar + n)
          · simp
          · exact (PNat.coe_le_coe ..).mp this
      ) vMapInj assumeVars)
  , by simp [LawfulState.withoutTemps, State.withoutTemps]
       intro s; split; simp; have := e.nextVar_mono_of_eq ‹_›
       simp [LawfulState.withTemps, State.withTemps] at this
       apply Nat.le_trans (m := s.nextVar + n)
       · apply Nat.le_add_right
       · exact (PNat.coe_le_coe ..).mp this⟩
