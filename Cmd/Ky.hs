-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE CPP #-}
-- | Load ky files, which are separate files containing call definitions.
-- The syntax is defined by 'Parse.parse_ky'.
module Cmd.Ky (
    update_cache
    , load
    , compile_library
#ifdef TESTING
    , module Cmd.Ky
#endif
) where
import qualified Control.Monad.Except as Except
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map as Map
import qualified System.FilePath as FilePath

import qualified Util.Doc as Doc
import qualified Util.Log as Log
import qualified Ui.State as State
import qualified Cmd.Cmd as Cmd
import qualified Derive.BaseTypes as BaseTypes
import qualified Derive.Call.Macro as Macro
import qualified Derive.Call.Module as Module
import qualified Derive.Derive as Derive
import qualified Derive.Eval as Eval
import qualified Derive.Library as Library
import qualified Derive.Parse as Parse
import qualified Derive.ShowVal as ShowVal
import qualified Derive.Sig as Sig

import Global


-- | Check if ky files have changed, and if they have, update
-- 'Cmd.state_ky_cache' and clear the performances.
update_cache :: State.State -> Cmd.State -> IO Cmd.State
update_cache ui_state cmd_state = do
    cache <- check_cache ui_state cmd_state
    return $ case cache of
        Nothing -> cmd_state
        Just ky_cache -> cmd_state
            { Cmd.state_ky_cache = Just ky_cache
            , Cmd.state_play = (Cmd.state_play cmd_state)
                { Cmd.state_performance = mempty
                , Cmd.state_current_performance = mempty
                , Cmd.state_performance_threads = mempty
                }
            }

-- | Reload the ky files if they're out of date, Nothing if no reload is
-- needed.
check_cache :: State.State -> Cmd.State -> IO (Maybe Cmd.KyCache)
check_cache ui_state cmd_state = run $ do
    when is_permanent abort
    (defs, imported) <- try $ Parse.load_ky (state_ky_paths cmd_state)
        (State.config#State.ky #$ ui_state)
    -- This uses the contents of all the files for the fingerprint, which
    -- means it has to read and parse them on each respond cycle.  If this
    -- turns out to be too expensive, I can go back to the modification time
    -- like I had before.
    let fingerprint = Cmd.fingerprint imported
    when (fingerprint == old_fingerprint) abort
    let lib = compile_library defs
    write_update_logs (map fst imported) lib
    return (lib, fingerprint)
    where
    is_permanent = case Cmd.state_ky_cache cmd_state of
        Just (Cmd.PermanentKy {}) -> True
        _ -> False
    old_fingerprint = case Cmd.state_ky_cache cmd_state of
        Just (Cmd.KyCache _ fprint) -> fprint
        _ -> mempty
    -- If it failed last time then don't replace the error.  Otherwise, I'll
    -- continually clear the performance and get an endless loop.
    failed_previously = case Cmd.state_ky_cache cmd_state of
        Just (Cmd.KyCache (Left _) _) -> True
        _ -> False

    abort = Except.throwError Nothing
    try action = tryRight . first Just =<< liftIO action
    run = fmap apply . Except.runExceptT
    apply (Left Nothing) = Nothing
    apply (Left (Just err))
        | failed_previously = Nothing
        | otherwise = Just $ Cmd.KyCache (Left err) mempty
    apply (Right (lib, fingerprint)) =
        Just $ Cmd.KyCache (Right lib) fingerprint

load :: [FilePath] -> State.State -> IO (Either Text Derive.Library)
load paths =
    fmap (fmap (compile_library . fst)) . Parse.load_ky paths
        . (State.config#State.ky #$)

write_update_logs :: Log.LogMonad m => [FilePath] -> Derive.Library -> m ()
write_update_logs imports lib = do
    let files = map (txt . FilePath.takeFileName) $ filter (not . null) imports
    Log.notice $ "reloaded ky " <> pretty files
    forM_ (Library.shadowed lib) $ \((call_type, _module), calls) ->
        Log.warn $ call_type <> " shadowed: " <> pretty calls

state_ky_paths :: Cmd.State -> [FilePath]
state_ky_paths cmd_state = maybe id (:) (Cmd.state_save_dir cmd_state)
    (Cmd.config_ky_paths (Cmd.state_config cmd_state))

compile_library :: Parse.Definitions -> Derive.Library
compile_library (Parse.Definitions note control pitch val aliases) =
    Derive.Library
        { lib_note = call_maps note
        , lib_control = call_maps control
        , lib_pitch = call_maps pitch
        , lib_val = Derive.call_map $ compile make_val_call val
        , lib_instrument_aliases = Map.fromList aliases
        }
    where
    call_maps (gen, trans) = Derive.call_maps
        (compile make_generator gen) (compile make_transformer trans)
    compile make = map $ \(fname, (call_id, expr)) ->
        (call_id, make fname (sym_to_name call_id) expr)
    sym_to_name (BaseTypes.Symbol name) = Derive.CallName name

make_generator :: Derive.Callable d => FilePath -> Derive.CallName
    -> Parse.Expr -> Derive.Generator d
make_generator fname name var_expr
    | Just expr <- no_free_vars var_expr = simple_generator fname name expr
    | otherwise = Macro.generator Module.local name mempty
        (Doc.Doc $ "Defined in " <> txt fname <> ".") var_expr

make_transformer :: Derive.Callable d => FilePath -> Derive.CallName
    -> Parse.Expr -> Derive.Transformer d
make_transformer fname name var_expr
    | Just expr <- no_free_vars var_expr = simple_transformer fname name expr
    | otherwise = Macro.transformer Module.local name mempty
        (Doc.Doc $ "Defined in " <> txt fname <> ".") var_expr

make_val_call :: FilePath -> Derive.CallName -> Parse.Expr -> Derive.ValCall
make_val_call fname name var_expr
    | Just expr <- no_free_vars var_expr = case expr of
        call_expr :| [] -> simple_val_call fname name call_expr
        _ -> broken
    | otherwise = case var_expr of
        Parse.Expr (call_expr :| []) -> Macro.val_call Module.local name mempty
            (Doc.Doc $ "Defined in " <> txt fname <> ".") call_expr
        _ -> broken
    where
    broken = broken_val_call name $
        "Broken val call defined in " <> txt fname
        <> ": val calls don't support pipeline syntax: "
        <> ShowVal.show_val var_expr

simple_generator :: Derive.Callable d => FilePath -> Derive.CallName
    -> BaseTypes.Expr -> Derive.Generator d
simple_generator fname name expr =
    Derive.generator Module.local name mempty (make_doc fname name expr) $
    case assign_symbol expr of
        Nothing -> Sig.call0 generator
        Just call_id ->
            Sig.call (Sig.many_vals "arg" "Args parsed by reapplied call.") $
                \_vals args -> Eval.reapply_generator args call_id
    where generator args = Eval.eval_toplevel (Derive.passed_ctx args) expr

simple_transformer :: Derive.Callable d => FilePath -> Derive.CallName
    -> BaseTypes.Expr -> Derive.Transformer d
simple_transformer fname name expr =
    Derive.transformer Module.local name mempty (make_doc fname name expr) $
    case assign_symbol expr of
        Nothing -> Sig.call0t transformer
        Just call_id ->
            Sig.callt (Sig.many_vals "arg" "Args parsed by reapplied call.") $
                \_vals -> reapply call_id
    where
    transformer args deriver =
        Eval.eval_transformers (Derive.passed_ctx args)
            (NonEmpty.toList expr) deriver
    reapply call_id args deriver = do
        call <- Eval.get_transformer call_id
        Eval.apply_transformer (Derive.passed_ctx args) call
            (Derive.passed_vals args) deriver

simple_val_call :: FilePath -> Derive.CallName -> BaseTypes.Call
    -> Derive.ValCall
simple_val_call fname name call_expr =
    Derive.val_call Module.local name mempty (make_doc fname name expr) $
    case assign_symbol expr of
        Nothing -> Sig.call0 $ \args ->
            Eval.eval (Derive.passed_ctx args) (BaseTypes.ValCall call_expr)
        Just call_id ->
            Sig.call (Sig.many_vals "arg" "Args parsed by reapplied call.") $
                \_vals -> call_args call_id
    where
    expr = call_expr :| []
    call_args call_id args = do
        call <- Eval.get_val_call call_id
        Derive.vcall_call call $ args
            { Derive.passed_call_name = Derive.vcall_name call }

broken_val_call :: Derive.CallName -> Text -> Derive.ValCall
broken_val_call name msg = Derive.make_val_call Module.local name mempty
    (Doc.Doc msg)
    (Sig.call (Sig.many_vals "arg" "broken") $ \_ _ -> Derive.throw msg)

-- | If the Parse.Expr has no 'Parse.VarTerm's, it doesn't need to be a macro.
no_free_vars :: Parse.Expr -> Maybe BaseTypes.Expr
no_free_vars (Parse.Expr expr) = traverse convent_call expr
    where
    convent_call (Parse.Call call_id terms) =
        BaseTypes.Call call_id <$> traverse convert_term terms
    convert_term (Parse.VarTerm _) = Nothing
    convert_term (Parse.ValCall call) = BaseTypes.ValCall <$> convent_call call
    convert_term (Parse.Literal val) = Just $ BaseTypes.Literal val

make_doc :: FilePath -> Derive.CallName -> BaseTypes.Expr -> Doc.Doc
make_doc fname name expr = Doc.Doc $
    pretty name <> " defined in " <> txt fname <> ": " <> ShowVal.show_val expr

-- | If there are arguments in the definition, then don't accept any in the
-- score.  I could do partial application, but it seems confusing, so
-- I won't add it unless I need it.
assign_symbol :: BaseTypes.Expr -> Maybe BaseTypes.CallId
assign_symbol (BaseTypes.Call call_id [] :| []) = Just call_id
assign_symbol _ = Nothing
