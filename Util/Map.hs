-- | Extra utils for "Data.Map".
module Util.Map where
import Data.Function
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Set as Set


get :: (Ord k) => a -> k -> Map.Map k a -> a
get def k fm = Maybe.fromMaybe def (Map.lookup k fm)

delete_keys :: (Ord k) => [k] -> Map.Map k a -> Map.Map k a
delete_keys keys fm = Map.difference fm (Map.fromList [(k, ()) | k <- keys])

-- | Like 'Data.Map.split', except include a matched key in the above map.
split2 :: (Ord k) => k -> Map.Map k a -> (Map.Map k a, Map.Map k a)
split2 k fm = (pre, post')
    where
    (pre, at, post) = Map.splitLookup k fm
    post' = maybe post (\v -> Map.insert k v post) at

-- | Split the map into the maps below, within, and above the given range.
-- @low@ to @high@ is half-open, as usual.
split3 :: (Ord k) => k -> k -> Map.Map k a
    -> (Map.Map k a, Map.Map k a, Map.Map k a)
split3 low high fm = (below, within, way_above)
    where
    (below, above) = split2 low fm
    (within, way_above) = split2 high above

-- | Return the subset of the map that is between a half-open low and high key.
within :: (Ord k) => k -> k -> Map.Map k a -> Map.Map k a
within low high fm = let (_, m, _) = split3 low high fm in m

invert :: (Ord k, Ord a) => Map.Map k a -> Map.Map a k
invert = Map.fromList . map (\(x, y) -> (y, x)) . Map.assocs

-- Would it be more efficient to do 'fromListWith (++)'?
multimap :: (Ord k, Ord a) => [(k, a)] -> Map.Map k [a]
multimap = Map.fromAscList . map (\gs -> (fst (head gs), map snd gs))
    . List.groupBy ((==) `on` fst) . List.sort

-- | Like Map.fromList, but only accept the first of duplicate keys, and also
-- return the rejected duplicates.
unique :: (Ord a) => [(a, b)] -> (Map.Map a b, [(a, b)])
unique assocs = (Map.fromList pairs, concat rest)
    where
    -- List.sort is stable, so only the first keys will make it into the map.
    separate = unzip . map (\((k, v):rest) -> ((k, v), rest))
        . List.groupBy ((==) `on` fst) . List.sortBy (compare `on` fst)
    (pairs, rest) = separate assocs

-- | Given two maps, pair up the elements in @map1@ with a samed-keyed element
-- in @map2@, if there is one.  Elements that are only in @map1@ or @map2@ will
-- not be included in the output.
zip_intersection :: (Ord k) => Map.Map k v1 -> Map.Map k v2 -> [(k, v1, v2)]
zip_intersection map1 map2 =
    [(k, v1, v2) | (k, v1) <- Map.assocs map1, Just v2 <- [Map.lookup k map2]]
    -- I could implement with 'pairs', but it would be less efficient.

-- | Pair up elements from each map with equal keys.
pairs :: (Ord k) => Map.Map k v1 -> Map.Map k v2 -> [(k, Maybe v1, Maybe v2)]
pairs map1 map2 = map (\k -> (k, Map.lookup k map1, Map.lookup k map2))
    (Set.toList (Set.union (Map.keysSet map1) (Map.keysSet map2)))

-- | Like Map.union, but also return a map of rejected duplicate keys from the
-- map on the right.
unique_union :: (Ord k) =>
    Map.Map k a -> Map.Map k a -> (Map.Map k a, Map.Map k a)
    -- Map.union is left biased, so dups will be thrown out.
unique_union fm0 fm1 = (Map.union fm0 fm1, lost)
    where lost = Map.intersection fm1 fm0

-- | Map.union says it's more efficient with @big `union` small@, so this one
-- flips the args to be more efficient.  It's still left-biased.
union2 :: (Ord k) => Map.Map k v -> Map.Map k v -> Map.Map k v
union2 m1 m2
    | Map.size m1 < Map.size m2 = m2 `right` m1
    | otherwise = m1 `Map.union` m2
    where right = Map.unionWith (\_ a -> a)

-- | Safe versions of findMin and findMax.
find_min :: Map.Map k a -> Maybe (k, a)
find_min fm
    | Map.null fm = Nothing
    | otherwise = Just (Map.findMin fm)

find_max :: Map.Map k a -> Maybe (k, a)
find_max fm
    | Map.null fm = Nothing
    | otherwise = Just (Map.findMax fm)
