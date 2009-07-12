module Util.Seq where

import qualified Data.Char as Char
import qualified Data.Maybe as Maybe
import qualified Data.Set as Set
import Data.Function
import Data.List


-- * transformation

enumerate :: [a] -> [(Int, a)]
enumerate = zip [0..]

key_with :: (a -> k) -> [a] -> [(k, a)]
key_with f xs = zip (map f xs) xs

-- * indexing lists

-- | Get @xs !! n@, but return Nothing if the index is out of range.
at :: [a] -> Int -> Maybe a
at xs n
    | n < 0 = Nothing
    | otherwise = _at xs n
    where
    _at [] _ = Nothing
    _at (x:_) 0 = Just x
    _at (_:xs) n = at xs (n-1)

at_err :: String -> [a] -> Int -> a
at_err msg xs n = Maybe.fromMaybe
    (error $ "Seq.at_err: " ++ msg ++ "; index " ++ show n ++ " out of range "
        ++ show (length xs))
    (at xs n)

-- | Insert @x@ into @xs@ at index @i@.  If @i@ is out of range, insert at the
-- beginning or end of the list.
insert_at :: [a] -> Int -> a -> [a]
insert_at xs i x = let (pre, post) = splitAt i xs in pre ++ (x : post)

-- | Remove the element at the given index.  Do nothing if the index is out
-- of range.
remove_at :: [a] -> Int -> [a]
remove_at xs i = let (pre, post) = splitAt i xs in pre ++ drop 1 post

-- | Modify element at an index by applying a function to it.  If the index is
-- out of range, nothing happens.
modify_at :: [a] -> Int -> (a -> a) -> [a]
modify_at xs i f = case post of
        [] -> pre
        (elt:rest) -> (pre ++ f elt : rest)
    where (pre, post) = splitAt i xs

-- * ordered lists

-- | Merge sorted lists.  If two elements compare equal, the one from the left
-- list comes first.
merge :: Ord a => [a] -> [a] -> [a]
merge = merge_by compare

-- | Non-overloaded version of 'merge'.
merge_by :: (a -> a -> Ordering) -> [a] -> [a] -> [a]
merge_by _ [] ys = ys
merge_by _ xs [] = xs
merge_by cmp xlist@(x:xs) ylist@(y:ys) = case cmp x y of
    GT -> y : merge_by cmp xlist ys
    _ -> x : merge_by cmp xs ylist

-- | Handy to merge or sort a descending list.
reverse_compare a b = case compare a b of
    LT -> GT
    EQ -> EQ
    GT -> LT


-- * grouping

-- | Group the unsorted list into @(key x, xs)@ where all @xs@ compare equal
-- after @key@ is applied to them.
keyed_group_with :: (Ord b) => (a -> b) -> [a] -> [(b, [a])]
keyed_group_with key = map (\gs -> (key (head gs), gs))
    . groupBy ((==) `on` key) . sortBy (compare `on` key)

-- | Pair each element with the following element.  The last element is paired
-- with Nothing.  Like @zip xs (drop 1 xs ++ f (last xs))@ but more efficient.
zip_next :: [a] -> [(a, Maybe a)]
zip_next [] = []
zip_next [x] = [(x, Nothing)]
zip_next (x : rest@(y:_)) = (x, Just y) : zip_next rest

-- * sublists

-- A foldr version is not lazy enough and overflows the stack.
partition_either [] = ([], [])
partition_either (x:xs) =
    let (ls, rs) = partition_either xs
    in case x of
        Left l -> (l:ls, rs)
        Right r -> (ls, r:rs)

-- ** extracting sublists

-- | Total variants of head and tail with default values.  "m" is for "maybe".
mhead :: a -> [a] -> a
mhead def [] = def
mhead _def (x:_) = x
mtail :: [a] -> [a] -> [a]
mtail def [] = def
mtail _def (_:xs) = xs

-- | Drop adjacent elts if the predicate says they are equal.  The first is
-- kept.
drop_dups :: (a -> a -> Bool) -> [a] -> [a]
drop_dups _ [] = []
drop_dups f (x:xs) = x : map snd (filter (not . uncurry f) (zip (x:xs) xs))

unique :: Ord a => [a] -> [a]
unique = unique_with id

unique_with :: Ord b => (a -> b) -> [a] -> [a]
unique_with f xs = go Set.empty xs
    where
    go _set [] = []
    go set (x:xs)
        | k `Set.member` set = go set xs
        | otherwise = x : go (Set.insert k set) xs
        where k = f x

rdrop :: Int -> [a] -> [a]
rdrop n = either (const []) id . foldr f (Left n)
    where
    f x (Left left)
        | left <= 0 = Right [x]
        | otherwise = Left (left-1)
    f x (Right xs) = Right (x:xs)

rdrop_while :: (a -> Bool) -> [a] -> [a]
rdrop_while f = foldr (\x xs -> if null xs && f x then [] else x:xs) []

lstrip = dropWhile Char.isSpace
rstrip = rdrop_while Char.isSpace
strip = rstrip . lstrip

-- ** splitting and joining

break_tails :: ([a] -> Bool) -> [a] -> ([a], [a])
break_tails _ [] = ([], [])
break_tails f lst@(x:xs)
    | f lst = ([], lst)
    | otherwise = let (pre, post) = break_tails f xs in (x:pre, post)

-- | Split @xs@ before places where @f@ matches.
--
-- > split_with (==1) [1,2,1]
-- > --> [[1, 2], [1]]
split_with :: (a -> Bool) -> [a] -> [[a]]
split_with f xs = map reverse (go f xs [])
    where
    go _ [] collect = [collect]
    go f (x:xs) collect
        | f x = collect : go f xs [x]
        | otherwise = go f xs (x:collect)

-- | Split 'xs' on 'sep', dropping 'sep' from the result.
split "" _ = error $ "Util.Seq.split: empty separator"
split sep xs = go sep xs
    where
    go sep xs
        | null post = [pre]
        | otherwise = pre : split sep (drop (length sep) post)
        where (pre, post) = break_tails (sep `isPrefixOf`) xs

-- | Split on commas and strip whitespace.
split_commas :: String -> [String]
split_commas = map strip . split ","

-- | Concat a list with 'sep' in between.
join sep = concat . intersperse sep

-- | Replace sublists in 'xs'.  'repl' is given the tails of 'xs' and can
-- return (replacement, rest_of_xs) or Nothing.
replaceWith :: ([a] -> Maybe ([a], [a])) -> [a] -> [a]
replaceWith _ [] = []
replaceWith repl xs = case repl xs of
    Just (insert, rest) -> insert ++ replaceWith repl rest
    Nothing -> head xs : replaceWith repl (tail xs)

-- | Replace sublist 'val' with 'repl' in the given list.
replace val repl = replaceWith (replaceVal val repl)

-- | Helper for replaceWith to replace a constant sublist 'val' with 'repl'.
replaceVal val repl xs
    | val `isPrefixOf` xs = Just (repl, drop (length val) xs)
    | otherwise = Nothing
