-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE ImplicitParams #-}
-- | A static macro is like a "Derive.Call.Macro", except that its calls
-- are given directly in haskell, instead of looked up as strings during
-- evaluation.  This means that the calls can't be rebound, but on the other
-- hand, it can re-export the documentation for the sub-calls.
module Derive.Call.StaticMacro (
    Call(..), Arg(..), call, literal
    , check
    , generator, transformer
) where
import qualified Control.Monad.Identity as Identity
import qualified Control.Monad.State as Monad.State
import qualified Data.List as List
import qualified Data.Text as Text
import qualified Data.Tuple as Tuple

import qualified Util.Log as Log
import qualified Util.TextUtil as TextUtil
import qualified Derive.BaseTypes as BaseTypes
import qualified Derive.Call.Module as Module
import qualified Derive.Call.Tags as Tags
import qualified Derive.Derive as Derive
import qualified Derive.Eval as Eval
import qualified Derive.ShowVal as ShowVal
import qualified Derive.Sig as Sig
import qualified Derive.Stream as Stream
import qualified Derive.Typecheck as Typecheck

import Global


data Call call = Call !call ![Arg] deriving (Show)
data Arg = Var | Given !Term deriving (Show)
data Term = ValCall !Derive.ValCall ![Arg] | Literal !BaseTypes.Val
    deriving (Show)

-- | A Term whose Vars have been filled in.
data ResolvedTerm =
    RValCall !Derive.ValCall ![ResolvedTerm] | RLiteral !BaseTypes.Val
    deriving (Show)

call :: Derive.ValCall -> [Arg] -> Arg
call c args = Given $ ValCall c args

literal :: Typecheck.ToVal a => a -> Arg
literal = Given . Literal . Typecheck.to_val

-- | Check the output of 'generator', 'transformer', or 'val' and crash if
-- it had a statically-detectable error.  Of course I'd much rather this
-- were a type error, but it's not worth breaking out TH for it.
check :: Log.Stack => String -> Either Text a -> a
check call_name (Left err) = error $ untxt (Log.show_stack ?stack) <> " - "
    <> call_name <> ": " <> untxt err
check _ (Right val) = val

generator :: Derive.Callable d => Module.Module -> Text -> Tags.Tags -> Text
    -> [Call (Derive.Transformer d)]
    -> Call (Derive.Generator d) -> Either Text (Derive.Generator d)
generator module_ name tags doc trans gen = do
    trans_args <- concatMapM extract_args trans
    gen_args <- extract_args gen
    let args = trans_args ++ gen_args
    return $ Derive.generator module_ name tags (make_doc doc call_docs) $
        Sig.call (Sig.many_vals args) $ \vals args ->
            generator_macro trans gen vals (Derive.passed_ctx args)
    where call_docs = map call_doc trans ++ [call_doc gen]

generator_macro :: Derive.Callable d => [Call (Derive.Transformer d)]
    -> Call (Derive.Generator d) -> [BaseTypes.Val] -> Derive.Context d
    -> Derive.Deriver (Stream.Stream d)
generator_macro trans gen vals ctx = do
    let (tcalls, trans_args) = unzip (map split trans)
    (vals, trans_args) <- return $
        List.mapAccumL substitute_vars vals trans_args
    (vals, gen_args) <- return $ substitute_vars vals (snd (split gen))
    unless (null vals) $ Derive.throw "more args than $vars"
    trans_args <- mapM (mapM (eval_term ctx)) trans_args
    gen_args <- mapM (eval_term ctx) gen_args
    Eval.apply_transformers ctx (zip tcalls trans_args) $
        Eval.apply_generator ctx (fst (split gen)) gen_args
    where
    split (Call call args) = (call, args)

transformer :: Derive.Callable d => Module.Module -> Text -> Tags.Tags -> Text
    -> [Call (Derive.Transformer d)] -> Either Text (Derive.Transformer d)
transformer module_ name tags doc trans = do
    args <- concatMapM extract_args trans
    return $ Derive.transformer module_ name tags (make_doc doc call_docs) $
        Sig.callt (Sig.many_vals args) $ \vals args ->
            transformer_macro trans vals (Derive.passed_ctx args)
    where call_docs = map call_doc trans

transformer_macro :: Derive.Callable d => [Call (Derive.Transformer d)]
    -> [BaseTypes.Val] -> Derive.Context d
    -> Derive.Deriver (Stream.Stream d) -> Derive.Deriver (Stream.Stream d)
transformer_macro trans vals ctx deriver = do
    let (tcalls, trans_args) = unzip (map split trans)
    (vals, trans_args) <- return $
        List.mapAccumL substitute_vars vals trans_args
    unless (null vals) $ Derive.throw "more args than $vars"
    trans_args <- mapM (mapM (eval_term ctx)) trans_args
    Eval.apply_transformers ctx (zip tcalls trans_args) deriver
    where
    split (Call call args) = (call, args)

eval_term :: Derive.Taggable a => Derive.Context a -> ResolvedTerm
    -> Derive.Deriver BaseTypes.Val
eval_term _ (RLiteral val) = return val
eval_term ctx (RValCall call terms) = do
    vals <- mapM (eval_term ctx) terms
    let passed = Derive.PassedArgs
            { passed_vals = vals
            , passed_call_name = Derive.vcall_name call
            , passed_ctx = Derive.tag_context ctx
            }
    Derive.vcall_call call passed

substitute_vars :: [BaseTypes.Val] -> [Arg] -> ([BaseTypes.Val], [ResolvedTerm])
substitute_vars vals args = run (mapM subst_arg args)
    where
    subst_arg arg = case arg of
        Var -> RLiteral <$> pop
        Given (Literal val) -> return (RLiteral val)
        Given (ValCall call args) -> RValCall call <$> mapM subst_arg args
    pop = do
        vals <- Monad.State.get
        case vals of
            -- This allows the sub-call look in the environ for a default.
            [] -> return BaseTypes.VNotGiven
            v : vs -> Monad.State.put vs >> return v
    run = Tuple.swap . Identity.runIdentity . flip Monad.State.runStateT vals

-- Look for Vars, and get the corresponding ArgDoc.
extract_args :: Call (Derive.Call f) -> Either Text [Derive.ArgDoc]
extract_args (Call call args) = extract (Derive.call_doc call) args
    where
    extract :: Derive.CallDoc -> [Arg] -> Either Text [Derive.ArgDoc]
    extract cdoc args = case Derive.cdoc_args cdoc of
        Derive.ArgDocs docs
            | length args > length docs -> Left $
                "call can take up to " <> showt (length docs)
                <> " args, but was given " <> showt (length args)
            | otherwise -> concatMapM extract_arg (zip docs args)
        Derive.ArgsParsedManually _ ->
            -- TODO This means an arbitrary number of Vals.  I think I'd have
            -- to insist on only one Var, and then give all the arguments to
            -- it.  It's not that hard, but I don't have a reason to support it
            -- at the moment.
            Left "ArgsParsedManually not supported"
        where
        extract_arg (doc, arg) = case arg of
            Var -> Right [doc]
            Given (Literal _) -> Right []
            Given (ValCall call args) -> extract (Derive.vcall_doc call) args

-- ** doc

make_doc :: Text -> [Text] -> Text
make_doc doc calls = TextUtil.joinWith "\n" doc $
    "A static macro for: `" <> Text.intercalate " | " calls <> "`.\
    \\nEach `$` is lifted to be an argument of this macro.\
    \\nThis directly calls the underlying sub-calls, so it's not dependent on\
    \ the names they are bound to, which also means the macro text may not be a\
    \ valid expression."

call_doc :: Call (Derive.Call f) -> Text
call_doc (Call call args) = Text.unwords $
    Derive.call_name call : map arg_doc args

arg_doc :: Arg -> Text
arg_doc (Given (Literal val)) = ShowVal.show_val val
arg_doc (Given (ValCall call args)) =
    "(" <> Text.unwords (Derive.vcall_name call : map arg_doc args) <> ")"
arg_doc Var = "$"