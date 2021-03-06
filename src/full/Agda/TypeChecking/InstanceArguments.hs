{-# LANGUAGE CPP #-}

module Agda.TypeChecking.InstanceArguments where

import Control.Applicative
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.State
import Data.Map as Map
import Data.List as List

import Agda.Syntax.Common
import Agda.Syntax.Position
import Agda.Syntax.Scope.Base
import Agda.Syntax.Internal
import Agda.TypeChecking.Irrelevance
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Reduce

import {-# SOURCE #-} Agda.TypeChecking.Constraints
import {-# SOURCE #-} Agda.TypeChecking.Rules.Term (checkArguments, ExpandHidden(..), ExpandInstances(..))
import {-# SOURCE #-} Agda.TypeChecking.MetaVars
import {-# SOURCE #-} Agda.TypeChecking.Conversion

import Agda.Utils.Monad

#include "../undefined.h"
import Agda.Utils.Impossible

initialIFSCandidates :: TCM [(Term, Type)]
initialIFSCandidates = do
  cands1 <- getContextVars
  cands2 <- getScopeDefs
  return $ cands1 ++ cands2
  where
    getContextVars :: TCM [(Term, Type)]
    getContextVars = do
      ctx <- getContext
      let ids = [0.. fromIntegral (length ctx) - 1] :: [Nat]
      types <- mapM typeOfBV ids
      let vars = [ (Var i [], t) | (Arg h r _, i, t) <- zip3 ctx [0..] types,
                                   not (unusableRelevance r) ]
      -- get let bindings
      env <- asks envLetBindings
      env <- mapM (getOpen . snd) $ Map.toList env
      let lets = [ (v,t) | (v, Arg h r t) <- env, not (unusableRelevance r) ]
      return $ vars ++ lets
    getScopeDefs :: TCM [(Term, Type)]
    getScopeDefs = do
      scopeInfo <- gets stScope
      let ns = everythingInScope scopeInfo
      let nsList = Map.toList $ nsNames ns
      -- all abstract names in scope are candidates
      -- (even ones that you can't refer to unambiguously)
      let cands2Names = nsList >>= snd
      cands2Types <- mapM (typeOfConst . anameName) cands2Names
      cands2Rel   <- mapM (relOfConst . anameName) cands2Names
      cands2FV    <- mapM (constrFreeVarsToApply . anameName) cands2Names
      rel         <- asks envRelevance
      return $ [(Def (anameName an) vs, t) |
                    (an, t, r, vs) <- zip4 cands2Names cands2Types cands2Rel cands2FV,
                    r `moreRelevant` rel ]
    constrFreeVarsToApply :: QName -> TCM Args
    constrFreeVarsToApply n = do
      args <- freeVarsToApply n
      defn <- theDef <$> getConstInfo n
      return $ case defn of
        -- drop parameters if it's a projection function...
        Function{ funProjection = Just (rn,i) } -> genericDrop (i - 1) args
        _                                       -> args


localState :: MonadState s m => m a -> m a
localState m = do
  s <- get
  x <- m
  put s
  return x

initializeIFSMeta :: Type -> TCM Term
initializeIFSMeta t = do
  cands <- initialIFSCandidates
  newIFSMeta t cands

findInScope :: MetaId -> [(Term, Type)] -> TCM ()
findInScope m cands = whenM (findInScope' m cands) $ do
    addConstraint $ FindInScope m cands

-- Result says whether we need to add constraint
findInScope' :: MetaId -> [(Term, Type)] -> TCM Bool
findInScope' m cands = ifM (isFrozen m) (return True) $ do
    reportSDoc "tc.constr.findInScope" 15 $ text ("findInScope 2: constraint: " ++ show m ++ "; candidates left: " ++ show (length cands))
    t <- getMetaTypeInContext m
    reportSLn "tc.constr.findInScope" 15 $ "findInScope 3: t: " ++ show t
    mv <- lookupMeta m
    cands <- checkCandidates m t cands
    reportSLn "tc.constr.findInScope" 15 $ "findInScope 4: cands left: " ++ show (length cands)
    case cands of
      [] -> do reportSDoc "tc.constr.findInScope" 15 $ text "findInScope 5: not a single candidate found..."
               typeError $ IFSNoCandidateInScope t

      [(term, t')] -> do reportSDoc "tc.constr.findInScope" 15 $ text (
                           "findInScope 5: one candidate found for type '") <+>
                           prettyTCM t <+> text "': '" <+> prettyTCM term <+>
                           text "', of type '" <+> prettyTCM t' <+> text "'."
                         ca <- liftTCM $ runErrorT $ checkArguments ExpandLast DontExpandInstanceArguments (getRange mv) [] t' t
                         case ca of Left _ -> __IMPOSSIBLE__
                                    Right (args, t'') -> do
                                      leqType t'' t
                                      ctxArgs <- getContextArgs
                                      assignV m ctxArgs (term `apply` args)
                                      return False
      cs -> do reportSDoc "tc.constr.findInScope" 15 $
                 text ("findInScope 5: more than one candidate found: ") <+>
                 prettyTCM (List.map fst cs)
               return True

-- return the meta's type, applied to the current context
getMetaTypeInContext :: MetaId -> TCM Type
getMetaTypeInContext m = do
  mv <- lookupMeta m
  let j = mvJudgement mv
  tj <- getMetaType m
  ctxArgs <- getContextArgs
  normalise $ tj `piApply` ctxArgs

-- returns a refined list of valid candidates and the (normalised) type of the
-- meta, applied to the context (for convenience)
checkCandidates :: MetaId -> Type -> [(Term, Type)] -> TCM [(Term, Type)]
checkCandidates m t cands = localState $ do
  -- for candidate checking, we don't take into account other IFS
  -- constrains
  dropConstraints (isIFSConstraint . clValue . theConstraint)
  filterM (uncurry $ checkCandidateForMeta m t) cands
  where
    checkCandidateForMeta :: MetaId -> Type -> Term -> Type -> TCM Bool
    checkCandidateForMeta m t term t' =
      liftTCM $ flip catchError (\err -> return False) $ do
        reportSLn "tc.constr.findInScope" 20 $ "checkCandidateForMeta\n  t: " ++ show t ++ "\n  t':" ++ show t' ++ "\n  term: " ++ show term ++ "."
        localState $ do
           -- domi: we assume that nothing below performs direct IO (except
           -- for logging and such, I guess)
          ca <- runErrorT $ checkArguments ExpandLast DontExpandInstanceArguments  noRange [] t' t
          case ca of
            Left _ -> return False
            Right (args, t'') -> do
              leqType t'' t
              --tel <- getContextTelescope
              ctxArgs <- getContextArgs
              assign m ctxArgs (term `apply` args)
              -- make a pass over constraints, to detect cases where some are made
              -- unsolvable by the assignment, but don't do this for FindInScope's
              -- to prevent loops. We currently also ignore UnBlock constraints
              -- to be on the safe side.
              solveAwakeConstraints' True
              return True
    isIFSConstraint :: Constraint -> Bool
    isIFSConstraint FindInScope{} = True
    isIFSConstraint _             = False

-- | Attempt to solve irrelevant metas by instance search.
solveIrrelevantMetas :: TCM ()
solveIrrelevantMetas = mapM_ solveMetaIfIrrelevant =<< getOpenMetas

solveMetaIfIrrelevant :: MetaId -> TCM ()
solveMetaIfIrrelevant x = do
  m <- lookupMeta x
  when (getMetaRelevance m == Irrelevant) $ do
    reportSDoc "tc.conv.irr" 20 $ sep
      [ text "instance search for solution of irrelevant meta"
      , prettyTCM x, colon, prettyTCM $ jMetaType $ mvJudgement m
      ]
    flip catchError (const $ return ()) $ do
      findInScope' x =<< initialIFSCandidates
      -- do not add constraints!
      return ()
