module Derive.TrackLang_test where
import Util.Test
import qualified Derive.ParseBs as ParseBs
import qualified Derive.ShowVal as ShowVal
import qualified Derive.TrackLang as TrackLang


test_map_symbol = do
    let f modify = ShowVal.show_val . TrackLang.map_symbol modify
            . expect_right "parse" . ParseBs.parse_expr . ParseBs.from_string
    -- Mostly this is testing that show_val is a proper inverse of
    -- ParseBs.parse_expr.
    equal (f (const (TrackLang.Symbol "1")) "23 23 '23' | 42")
        "1 23 '1' | 1"
