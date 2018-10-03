{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns        #-}
{-# LANGUAGE DoAndIfThenElse     #-}

module Unison.Codebase.Branch where

--import Control.Monad (join)
--import Data.List.NonEmpty (nonEmpty)
import           Control.Monad              (foldM)
import           Data.Map                   (Map)
import           Data.Set                   (Set)
import qualified Data.Set                   as Set
--import Data.Semigroup (sconcat)
import           Data.Foldable
import qualified Data.Map                   as Map
import           Unison.Codebase.Causal     (Causal)
import qualified Unison.Codebase.Causal     as Causal
import           Unison.Codebase.Conflicted (Conflicted)
import qualified Unison.Codebase.Conflicted as Conflicted
import           Unison.Codebase.Name       (Name)
import           Unison.Hashable            (Hashable)
import qualified Unison.Hashable            as H
-- import Unison.Codebase.NameEdit (NameEdit)
import           Unison.Codebase.TermEdit   (TermEdit, Typing)
import qualified Unison.Codebase.TermEdit   as TermEdit
import           Unison.Codebase.TypeEdit   (TypeEdit)
import qualified Unison.Codebase.TypeEdit   as TypeEdit
import           Unison.Reference           (Reference)

-- todo:
-- probably should refactor Reference to include info about whether it
-- is a term reference, a type decl reference, or an effect decl reference
-- (maybe combine last two)
--
-- While we're at it, should add a `Cycle Int [Reference]` for referring to
-- an element of a cycle of references.
--
-- If we do that, can implement various operations safely since we'll know
-- if we are referring to a term or a type (and can prevent adding a type
-- reference to the term namespace, say)

-- A `Branch`, `b` should likely maintain that:
--
--  * If `r : Reference` is in `codebase b` or one of its
--    transitive dependencies then `b` should have a `Name` for `r`.
--
-- This implies that if you depend on some code, you pick names for that
-- code. The editing tool will likely pick names based on some convention.
-- (like if you import and use `Runar.foo` in a function you write, it will
--  republished under `dependencies.Runar`. Could also potentially put
--  deps alongside the namespace...)
--
-- Thought was that basically don't need `Release`, it's just that
-- some branches are unconflicted and we might indicate that in some way
-- in the UI.
--
-- To "delete" a definition, just remove it from the map.
--
-- Operations around making transitive updates, resolving conflicts...
-- determining remaining work before one branch "covers" another...
newtype Branch = Branch (Causal Branch0)

data Branch0 =
  Branch0 { termNamespace :: Map Name (Conflicted Reference)
          , typeNamespace :: Map Name (Conflicted Reference)
          , edited        :: Map Reference (Conflicted TermEdit)
          , editedDatas   :: Map Reference (Conflicted TypeEdit)
          , editedEffects :: Map Reference (Conflicted TypeEdit)
          , backupNames   :: Map Reference (Set Name)
          -- , codebase       :: Set Reference
          }

instance Semigroup Branch0 where
  Branch0 n1 nt1 t1 d1 e1 dp1 <> Branch0 n2 nt2 t2 d2 e2 dp2 = Branch0
    (Map.unionWith (<>) n1 n2)
    (Map.unionWith (<>) nt1 nt2)
    (Map.unionWith (<>) t1 t2)
    (Map.unionWith (<>) d1 d2)
    (Map.unionWith (<>) e1 e2)
    (Map.unionWith (<>) dp1 dp2)

merge :: Branch -> Branch -> Branch
merge (Branch b) (Branch b2) = Branch (Causal.merge b b2)

data ReferenceOps m = ReferenceOps
  { name         :: Reference -> m (Set Name)
  , isTerm       :: Reference -> m Bool
  , isType       :: Reference -> m Bool
  , dependencies :: Reference -> m (Set Reference)
  -- , dependencies ::
  }

-- 0. bar depends on foo
-- 1. replace foo with foo'
-- 2. replace bar with bar' which depends on foo'
-- 3. replace foo' with foo''
-- "foo" points to foo''
-- "bar" points to bar'
--
-- foo -> Replace foo'
-- foo' -> Replace foo''
-- bar -> Replace bar'
--
-- foo -> Replace foo''
-- foo' -> Replace foo''
-- bar -> Replace bar'
--
-- foo -> Replace foo''
-- bar -> Replace bar''
-- foo' -> Replace foo'' *optional
-- bar' -> Replace bar'' *optional

add :: Monad m => ReferenceOps m -> Name -> Reference -> Branch -> m Branch
add ops n r (Branch b) = Branch <$> Causal.stepM go b where
  go b = do
    -- add dependencies to `backupNames`
    backupNames' <- updateBackupNames1 ops r b
    -- add (n,r) to backupNames
    let backupNames'' = Map.insertWith (<>) r (Set.singleton n) backupNames'
    -- add to appropriate namespace
    isTerm <- isTerm ops r
    isType <- isType ops r
    if isTerm then
      pure b { termNamespace = Conflicted.singletonMap n r <> termNamespace b
             , backupNames = backupNames''
             }
    else if isType then
      pure b { typeNamespace = Conflicted.singletonMap n r <> typeNamespace b
             , backupNames = backupNames''
             }
    else error $ "Branch.add received unknown reference " ++ show r

updateBackupNames :: Monad m
                  => ReferenceOps m
                  -> Set Reference
                  -> Branch0
                  -> m (Map Reference (Set Name))
updateBackupNames ops refs b = do
  transitiveClosure <- transitiveClosure (dependencies ops) refs
  foldM insertNames (backupNames b) transitiveClosure
  where
    insertNames m r = Map.insertWith (<>) r <$> name ops r <*> pure m

updateBackupNames1 :: Monad m
                   => ReferenceOps m
                   -> Reference
                   -> Branch0
                   -> m (Map Reference (Set Name))
updateBackupNames1 ops r b = updateBackupNames ops (Set.singleton r) b

replaceTerm :: Monad m
            => ReferenceOps m
            -> Reference -> Reference -> Typing
            -> Branch -> m Branch
replaceTerm ops old new typ (Branch b) = Branch <$> Causal.stepM go b where
  edit = Conflicted.one (TermEdit.Replace new typ)
  replace cs = Conflicted.map (\r -> if r == old then new else r) cs
  go b = do
    backupNames <- updateBackupNames1 ops new b
    pure b { edited = Map.insertWith (<>) old edit (edited b)
    -- todo: can we use backupNames to find the keys to update, instead of fmap
           , termNamespace = replace <$> termNamespace b
           , backupNames = backupNames
           }

codebase :: Monad m => ReferenceOps m -> Branch -> m (Set Reference)
codebase ops (Branch (Causal.head -> Branch0 {..})) =
  let initial = Set.fromList $
        (toList termNamespace >>= toList) ++
        (toList typeNamespace >>= toList) ++
        (toList edited >>= toList >>= TermEdit.references) ++
        (toList editedDatas >>= toList >>= TypeEdit.references) ++
        (toList editedEffects >>= toList >>= TypeEdit.references)
  in transitiveClosure (dependencies ops) initial

transitiveClosure :: forall m a. (Monad m, Ord a)
                  => (a -> m (Set a))
                  -> Set a
                  -> m (Set a)
transitiveClosure getDependencies open =
  let go :: Set a -> [a] -> m (Set a)
      go closed [] = pure closed
      go closed (h:t) =
        if Set.member h closed
          then go closed t
        else do
          deps <- getDependencies h
          go (Set.insert h closed) (toList deps ++ t)
  in go Set.empty (toList open)

-- foo -> (bar, baz)
-- bar -> id
-- baz -> goo

-- transitiveClosure ... { foo, baz }
-- go {} [foo, baz]
--   deps foo = {bar, baz}
-- go {foo} [bar, baz, baz]
--   deps bar = {id}
-- go {foo, bar} [id, baz, baz]
--   deps id = {}
-- go {foo, bar, id} [baz, baz]
--   deps baz = {goo}
-- go {foo, bar, id, baz} [goo, baz]
--   deps goo = {}
-- go {foo, goo, bar, baz, id} [baz]
-- go {foo, goo, bar, baz, id} []
-- {foo, goo, bar, baz, id}




--apply :: Branch -> Map Name Reference -> Map Name (Conflicted Reference)
--apply (Branch (Causal.head -> Branch0 {..})) ns = let
--  nsOut = Map.unionWith (<>) termNamespace typeNamespace
--  error "todo"



deprecateTerm :: Reference -> Branch -> Branch
deprecateTerm old (Branch b) = Branch $ Causal.step go b where
  edit = Conflicted.one TermEdit.Deprecate
  delete c = Conflicted.delete old c
  go b = b { edited = Map.insertWith (<>) old edit (edited b)
           , termNamespace = Map.fromList
             [ (k, v) | (k, v0) <- Map.toList (termNamespace b),
                        Just v <- [delete v0] ] }

instance Hashable Branch0 where
  tokens (Branch0 {..}) =
    H.tokens termNamespace ++ H.tokens typeNamespace ++
    H.tokens edited ++ H.tokens editedDatas ++ H.tokens editedEffects

type ResolveReference = Reference -> Maybe Name

resolveTerm :: Name -> Branch -> Maybe (Conflicted Reference)
resolveTerm n (Branch (Causal.head -> b)) =
  Map.lookup n (termNamespace b)

resolveTermUniquely :: Name -> Branch -> Maybe Reference
resolveTermUniquely n b = resolveTerm n b >>= Conflicted.asOne


-- probably not super common
--addName :: Reference -> Name -> Branch -> Branch
--addName r new b = Branch $ Causal.step go b where
--  ro = Conflicted.one r
--  go b = b { termNamespace = Map.insert n ro (termNamespace b) }

addTerm :: Name -> Reference -> Branch -> Branch
addTerm n r (Branch b) = Branch $ Causal.step go b where
  ro = Conflicted.one r
  go b = b { termNamespace = Map.insert n ro (termNamespace b) }

addType :: Name -> Reference -> Branch -> Branch
addType n r (Branch b) = Branch $ Causal.step go b where
  ro = Conflicted.one r
  go b = b { termNamespace = Map.insert n ro (typeNamespace b) }

renameType :: Name -> Name -> Branch -> Branch
renameType old new (Branch b) =
  let
    bh = Causal.head b
    m0 = typeNamespace bh
  in Branch $ case Map.lookup old m0 of
    Nothing -> b
    Just rs ->
      let m1 = Map.insertWith (<>) new rs . Map.delete old $ m0
      in Causal.cons (bh { typeNamespace = m1 }) b

renameTerm :: Name -> Name -> Branch -> Branch
renameTerm old new (Branch b) =
  let
    bh = Causal.head b
    m0 = termNamespace bh
  in Branch $ case Map.lookup old m0 of
    Nothing -> b
    Just rs ->
      let m1 = Map.insertWith (<>) new rs . Map.delete old $ m0
      in Causal.cons (bh { termNamespace = m1 }) b

--
-- What does this actually do.
--sequence :: Branch v a -> Branch v a -> Branch v a
--sequence (Branch n1 t1 d1 e1) (Branch n2 t2 d2 e2) =
--  Branch (Map.unionWith Causal.sequence n1 n2)
--          (chain ) _

-- example:
-- in b1: foo is replaced with Conflicted (foo1, foo2)
-- in b2: foo1 is replaced with foo3
-- what do we want the output to be?
--    foo  -> Conflicted (foo3, foo2)
--    foo1 -> foo3

-- example:
-- in b1: foo is replaced with Conflicted (foo1, foo2)
-- in b2: foo1 is replaced with foo2
-- what do we want the output to be?
--    foo  -> foo2
--    foo1 -> foo2

-- example:
-- in b1: foo is replaced with Conflicted (foo1, foo2)
-- in b2: foo is replaced with foo2
-- what do we want the output to be?
--    foo -> foo2

-- v = Causal (Conflicted blah)
-- k = Reference

--bindMaybeCausal ::forall a. (Hashable a, Ord a) => Causal (Conflicted a) -> (a -> Maybe (Causal (Conflicted a))) -> Causal (Conflicted a)
--bindMaybeCausal cca f = case Causal.head cca of
--  Conflicted.One a -> case f a of
--    Just cca' -> Causal.sequence cca cca'
--    Nothing -> cca
--  Conflicted.Many as ->
--    Causal.sequence cca $ case nonEmpty . join $ (toList . f <$> toList as) of
--      -- Would be nice if there were a good NonEmpty.Set, but Data.NonEmpty.Set from `non-empty` doesn't seem to be it.
--      Nothing -> error "impossible, `as` was Many"
--      Just z -> sconcat z
--
--chain :: forall v k. Ord k => (v -> Maybe k) -> Map k (Causal (Conflicted v)) -> Map k (Causal (Conflicted v)) -> Map k (Causal (Conflicted v))
--chain toK m1 m2 =
--    let
--      chain' :: forall v k . (v -> Maybe k) -> (k -> Maybe (Causal (Conflicted v))) -> (k -> Maybe (Causal (Conflicted v))) -> (k -> Maybe (Causal (Conflicted v)))
--      chain' toK m1 m2 k = case m1 k of
--        Just ccv1 -> Just $ bindMaybeCausal ccv1 (\k -> m2 k >>= toK)
--        Nothing -> m2 k
--    in
--      Map.fromList
--        [ (k, v) | k <- Map.keys m1 ++ Map.keys m2
--                 , Just v <- [chain' toK (`Map.lookup` m1) (`Map.lookup` m2) k] ]
