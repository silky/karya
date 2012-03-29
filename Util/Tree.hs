-- | Some more utilities for "Data.Tree".
module Util.Tree where
import Control.Monad
import qualified Data.List as List
import qualified Data.Tree as Tree
import Data.Tree (Tree(..), Forest)


-- | The edges of a forest, as (parent, child).
edges :: Forest a -> [(a, a)]
edges = concatMap $ \(Node val subs) ->
    [(val, sub_val) | Node sub_val _ <- subs] ++ edges subs

-- | Get every element along with its parents.  The parents are closest first
-- root last.
paths :: Forest a -> [(Tree a, [Tree a])]
paths = concatMap (go [])
    where
    go parents tree@(Node _ subs) =
        (tree, parents) : concatMap (go (tree:parents)) subs

-- | Like 'paths' but the parents and children have been flattened.
flat_paths :: Forest a -> [(a, [a], [a])]
    -- ^ (element, parents, children).  Parents are closest first root last,
    -- children are in depth first order.
flat_paths = map flatten . paths
    where
    flatten (Node val subs, parents) =
        (val, map Tree.rootLabel parents, concatMap Tree.flatten subs)

-- | Given a predicate, return the first depthwise matching element and
-- its children.
find :: (a -> Bool) -> Forest a -> Maybe (Tree a)
find p trees = case List.find (p . rootLabel) trees of
    Nothing -> msum $ map (find p . subForest) trees
    Just tree -> Just tree

-- | Like 'paths', but return only the element that matches the predicate.
find_with_parents :: (a -> Bool) -> Forest a -> Maybe (Tree a, [Tree a])
find_with_parents f = List.find (f . Tree.rootLabel . fst) . paths

-- | Find the first leaf, always taking the leftmost branch.
first_leaf :: Tree a -> a
first_leaf (Node a []) = a
first_leaf (Node _ (child : _)) = first_leaf child

leaves :: Forest a -> [Tree a]
leaves trees = do
    tree <- trees
    if null (subForest tree) then [tree] else leaves (subForest tree)
