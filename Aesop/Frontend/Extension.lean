/-
Copyright (c) 2023 Jannis Limperg. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jannis Limperg
-/

import Aesop.Frontend.Extension.Init

open Lean

namespace Aesop.Frontend

def extensionDescr (rsName : RuleSetName) :
    SimpleScopedEnvExtension.Descr RuleSetMember RuleSet where
  name := rsName
  addEntry rs r := rs.add r
  initial := ∅

def declareRuleSetUnchecked (rsName : RuleSetName) : IO Unit := do
  let ext ← registerSimpleScopedEnvExtension $ extensionDescr rsName
  aesopExtensionsMapRef.modify (·.insert rsName ext)

def isRuleSetDeclared (rsName : RuleSetName) : IO Bool :=
  return (← aesopExtensionsMapRef.get).contains rsName

variable [Monad m] [MonadError m] [MonadLiftT IO m]
  [MonadLiftT (ST IO.RealWorld) m] [MonadEnv m] [MonadResolveName m]

def checkRuleSetNotDeclared (rsName : RuleSetName) : m Unit := do
  if ← isRuleSetDeclared rsName then
    throwError "rule set '{rsName}' already exists"

def declareRuleSet (rsName : RuleSetName) : m Unit := do
  checkRuleSetNotDeclared rsName
  declareRuleSetUnchecked rsName

initialize builtinRuleSetNames.forM declareRuleSetUnchecked

def getRuleSetExtension (rsName : RuleSetName) : m RuleSetExtension := do
  let (some ext) := (← aesopExtensionsMapRef.get).find? rsName
    | throwError "no such rule set: '{rsName}'\n  (Use 'declare_aesop_rule_set' to declare rule sets.\n   Declared rule sets are not visible in the current file; they only become visible once you import the declaring file.)"
  return ext

def getRuleSet (rsName : RuleSetName) (includeGlobalSimpTheorems : Bool) :
    CoreM RuleSet := do
  let rs := (← getRuleSetExtension rsName).getState (← getEnv)
  if includeGlobalSimpTheorems && rsName == defaultRuleSetName then
    let normSimpLemmas :=
      SimpTheorems.merge (← Meta.getSimpTheorems) rs.normSimpLemmas
    return { rs with normSimpLemmas }
  else
    return rs

def getRuleSets (rsNames : Array RuleSetName)
    (includeGlobalSimpTheorems : Bool) : CoreM RuleSets :=
  rsNames.foldlM (init := ∅) λ rss rsName => do
    let rs ← getRuleSet rsName includeGlobalSimpTheorems
    return rss.addRuleSet rsName rs

def getDefaultRuleSets (includeGlobalSimpTheorems : Bool) : CoreM RuleSets :=
  getRuleSets defaultEnabledRuleSetNames includeGlobalSimpTheorems

def getDefaultRuleSet (includeGlobalSimpTheorems : Bool) (options : Options) :
    CoreM RuleSet :=
  return (← getDefaultRuleSets includeGlobalSimpTheorems).getMergedRuleSet
    options

def getAllRuleSets (includeGlobalSimpTheorems : Bool) : CoreM RuleSets := do
  (← aesopExtensionsMapRef.get).foldM (init := ∅) λ rss rsName _ =>
    return rss.addRuleSet rsName (← getRuleSet rsName includeGlobalSimpTheorems)

def addRuleUnchecked (rsName : RuleSetName) (r : RuleSetMember)
    (kind : AttributeKind) : m Unit := do
  let ext ← getRuleSetExtension rsName
  ext.add r kind

def addRule (rsName : RuleSetName) (r : RuleSetMember) (kind : AttributeKind) :
    m Unit := do
  let ext ← getRuleSetExtension rsName
  let rs := ext.getState (← getEnv)
  if rs.contains r.name then
    throwError "Rule '{r.name.name}' is already registered in rule set '{rsName}'."
  ext.add r kind

def eraseRules (rsf : RuleSetNameFilter) (rf : RuleNameFilter) (check : Bool) :
    m Unit := do
  match rsf.matchedRuleSetNames with
  | none =>
    let anyErased ←
      (← aesopExtensionsMapRef.get).foldM (init := false) λ b _ ext => go b ext
    if check && ! anyErased then
      throwError "'{rf.ident.name}' is not registered (with the given features) in any rule set."
  | some rsNames =>
    let anyErased ←
      rsNames.foldlM (init := false) λ b rsName => do
        go b (← getRuleSetExtension rsName)
    if check && ! anyErased then
      throwError "'{rf.ident.name}' is not registered (with the given features) in any of the rule sets {rsNames.map toString}."
  where
    go (anyErased : Bool) (ext : RuleSetExtension) : m Bool := do
      let env ← getEnv
      let (rs, rsErased) := ext.getState env |>.erase rf
      setEnv $ ext.modifyState env λ _ => rs
      return anyErased || rsErased

end Aesop.Frontend
