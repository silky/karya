module Ui.StyleC (insert_style) where
import Util.ForeignC
import qualified Ui.Style as Style


insert_style :: Style.StyleId -> Style.Style -> IO ()
insert_style (Style.StyleId style_id) style =
    with style $ \stylep -> c_insert_style (fromIntegral style_id) stylep

foreign import ccall "insert_style"
    c_insert_style :: CUChar -> Ptr Style.Style -> IO ()
