--------------------------------------------------------------------------------
-- |
-- Module : Dhek.PDF.Type
--
--
--------------------------------------------------------------------------------
module Dhek.PDF.Type where

--------------------------------------------------------------------------------
data PageDimension
    = A2_P
    | A2_L
    | A3_P
    | A3_L
    | A4_P
    | A4_L
    | A5_P
    | A5_L
    deriving (Show, Enum)

--------------------------------------------------------------------------------
newtype PageCount = PageCount { getPageNumber :: Int }
