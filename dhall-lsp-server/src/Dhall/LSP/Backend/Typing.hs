module Dhall.LSP.Backend.Typing (annotateLet, exprAt, srcAt, typeAt) where

import Dhall.Context (Context, insert, empty)
import Dhall.Core (Expr(..), subExpressions, normalize, shift, subst, Var(..), pretty)
import Dhall.TypeCheck (typeWithA, X, TypeError(..))
import Dhall.Parser (Src(..))

import Data.Monoid ((<>))
import Control.Lens (toListOf)
import Data.Text (Text)
import Control.Applicative ((<|>))
import Data.Bifunctor (first)
import Data.Void (absurd)

import Dhall.LSP.Backend.Parsing (getLetAnnot, getLetIdentifier,
  getLamIdentifier, getForallIdentifier)
import Dhall.LSP.Backend.Diagnostics (Position, Range(..), rangeFromDhall)
import Dhall.LSP.Backend.Dhall (WellTyped, fromWellTyped)

-- | Find the type of the subexpression at the given position. Assumes that the
--   input expression is well-typed. Also returns the Src descriptor containing
--   that subexpression if possible.
typeAt :: Position -> WellTyped -> Either String (Maybe Src, Expr Src X)
typeAt pos expr = do
  let expr' = fromWellTyped expr
  (mSrc, typ) <- first show $ typeAt' pos empty expr'
  case mSrc of
    Just src -> return (Just src, normalize typ)
    Nothing -> return (srcAt pos expr', normalize typ)

typeAt' :: Position -> Context (Expr Src X) -> Expr Src X -> Either (TypeError Src X) (Maybe Src, Expr Src X)
-- the user hovered over the bound name in a let expression
typeAt' pos ctx (Note src (Let _ _ a _)) | pos `inside` getLetIdentifier src = do
  typ <- typeWithA absurd ctx a
  return (Just $ getLetIdentifier src, typ)

-- "..." in a lambda expression
typeAt' pos _ctx (Note src (Lam _ _A _)) | Just src' <- getLamIdentifier src
                                         , pos `inside` src' =
  return (Just src', _A)

-- "..." in a forall expression
typeAt' pos _ctx (Note src (Pi _ _A _)) | Just src' <- getForallIdentifier src
                                        , pos `inside` src' =
  return (Just src', _A)

-- the input only contains singleton lets
typeAt' pos ctx (Let x _ a e@(Note src _)) | pos `inside` src = do
  _ <- typeWithA absurd ctx a
  let a' = shift 1 (V x 0) (normalize a)
  typeAt' pos ctx (shift (-1) (V x 0) (subst (V x 0) a' e))

typeAt' pos ctx (Lam x _A b@(Note src _)) | pos `inside` src = do
  let _A' = Dhall.Core.normalize _A
      ctx' = fmap (shift 1 (V x 0)) (insert x _A' ctx)
  typeAt' pos ctx' b

typeAt' pos ctx (Pi x _A  _B@(Note src _)) | pos `inside` src = do
  let _A' = Dhall.Core.normalize _A
      ctx' = fmap (shift 1 (V x 0)) (insert x _A' ctx)
  typeAt' pos ctx' _B

-- peel off a single Note constructor
typeAt' pos ctx (Note _ expr) = typeAt' pos ctx expr

-- catch-all
typeAt' pos ctx expr = do
  let subExprs = toListOf subExpressions expr
  case [ (src, e) | (Note src e) <- subExprs, pos `inside` src ] of
    [] -> do typ <- typeWithA absurd ctx expr  -- return type of whole subexpression
             return (Nothing, typ)
    ((src, e):_) -> typeAt' pos ctx (Note src e)  -- continue with leaf-expression


-- | Find the smallest Note-wrapped expression at the given position.
exprAt :: Position -> Expr Src a -> Maybe (Expr Src a)
exprAt pos e@(Note _ expr) = exprAt pos expr <|> Just e
exprAt pos expr =
  let subExprs = toListOf subExpressions expr
  in case [ (src, e) | (Note src e) <- subExprs, pos `inside` src ] of
    [] -> Nothing
    ((src,e) : _) -> exprAt pos e <|> Just (Note src e)


-- | Find the smallest Src annotation containing the given position.
srcAt :: Position -> Expr Src a -> Maybe Src
srcAt pos expr = do Note src _ <- exprAt pos expr
                    return src


-- | Given a well-typed expression and a position find the let binder at that
--   position (if there is one) and return a textual update to the source code
--   that inserts the type annotation (or replaces the existing one). If
--   something goes wrong returns a textual error message.
annotateLet :: Position -> WellTyped -> Either String (Src, Text)
annotateLet pos expr = do
  annotateLet' pos empty (fromWellTyped expr)

annotateLet' :: Position -> Context (Expr Src X) -> Expr Src X -> Either String (Src, Text)
-- the input only contains singleton lets
annotateLet' pos ctx (Note src e@(Let _ _ a _))
  | not $ any (pos `inside`) [ src' | Note src' _ <- toListOf subExpressions e ]
  = do _A <- first show $ typeWithA absurd ctx a
       srcAnnot <- case getLetAnnot src of
                     Just x -> return x
                     Nothing -> Left "The impossible happened: failed\
                                     \ to re-parse a Let expression."
       return (srcAnnot, ": " <> pretty (normalize _A) <> " ")

-- binders, see typeAt'
annotateLet' pos ctx (Let x _ a e@(Note src _)) | pos `inside` src = do
  _ <- first show $ typeWithA absurd ctx a
  let a' = shift 1 (V x 0) (normalize a)
  annotateLet' pos ctx (shift (-1) (V x 0) (subst (V x 0) a' e))

annotateLet' pos ctx (Lam x _A b@(Note src _)) | pos `inside` src = do
  let _A' = Dhall.Core.normalize _A
      ctx' = fmap (shift 1 (V x 0)) (insert x _A' ctx)
  annotateLet' pos ctx' b

annotateLet' pos ctx (Pi x _A _B@(Note src _)) | pos `inside` src = do
  let _A' = Dhall.Core.normalize _A
      ctx' = fmap (shift 1 (V x 0)) (insert x _A' ctx)
  annotateLet' pos ctx' _B

-- we need to unfold Notes to make progress
annotateLet' pos ctx (Note _ expr) = do
  annotateLet' pos ctx expr

-- catch-all
annotateLet' pos ctx expr = do
  let subExprs = toListOf subExpressions expr
  case [ Note src e | (Note src e) <- subExprs, pos `inside` src ] of
    (e:[]) -> annotateLet' pos ctx e
    _ -> Left "You weren't pointing at a let binder!"

-- Check if range lies completely inside a given subexpression.
-- This version takes trailing whitespace into account
-- (c.f. `sanitiseRange` from Backend.Diangostics).
inside :: Position -> Src -> Bool
inside pos src = left <= pos && pos < right
  where Range left right = rangeFromDhall src
