-- | Step combinators on 'Circuit' @arr@ 'Either'.
--
-- The 'Either' tensor gives iteration via 'Trace': 'Left' continues,
-- 'Right' exits.  These combinators intercept the feedback loop by
-- pattern-matching on constructors.
--
-- 'take' prepends a countdown to the feedback state (not supported
-- on 'Compose').  'filter' and 'compact' retry from seed by calling
-- the body a second time to extract a feedback value.
module Circuit.Step
  ( take,
    filter,
    compact,
  )
where

import Circuit (Circuit (..), reify)
import Data.Maybe (fromMaybe)
import Prelude hiding (filter, take)

-- $setup
-- >>> import Circuit (Circuit(..), reify)
-- >>> import Circuit.Step
-- >>> :set -Wno-overlapping-patterns

-- | Take at most @n@ iterations of the feedback loop.
-- Errors if the body hasn't exited after @n@ steps.
-- Not supported on 'Compose'.
take :: Int -> Circuit (->) Either s a -> Circuit (->) Either (Int, s) a
take n = \case
  Lift f -> Lift (f . snd)
  Knot body -> Knot $ Lift $ \case
    Left (i, f) -> go i (Left f)
    Right (i, s) -> go i (Right s)
    where
      go i x = case reify body x of
        Right a -> Right a
        Left x'
          | i > 1 -> Left (i - 1, x')
          | otherwise -> Right (error $ "take " <> show n <> ": exceeded limit")
  Compose _ _ -> error "take: Compose not supported"

-- | Skip exits that don't satisfy the predicate, retrying from seed.
-- Bottoms if no satisfying value is ever produced.
filter :: (a -> Bool) -> Circuit (->) Either x a -> Circuit (->) Either x a
filter p = \case
  Lift f -> Lift (fmap check f)
    where
      check a
        | p a = a
        | otherwise = error "filter: Lift rejected"
  Knot body -> Knot $ Lift $ \case
    Left f -> case reify body (Left f) of
      Right a
        | p a -> Right a
        | otherwise -> Left f
      Left f' -> Left f'
    Right x -> case reify body (Right x) of
      Right a
        | p a -> Right a
        | otherwise -> retry x
      Left f' -> Left f'
    where
      retry x = case reify body (Right x) of
        Left f -> Left f
        Right _ -> error "filter: stuck (body returned same unwanted value)"
  Compose f g -> Compose (filter p f) g

-- | Skip 'Nothing' exits, retrying until a 'Just' arrives.
-- Bottoms if no 'Just' ever arrives.
compact :: Circuit (->) Either x (Maybe a) -> Circuit (->) Either x a
compact = \case
  Lift f -> Lift (fmap (fromMaybe (error "compact: Lift returned Nothing")) f)
  Knot body -> Knot $ Lift $ \case
    Left f -> case reify body (Left f) of
      Right (Just a) -> Right a
      Right Nothing -> Left f
      Left f' -> Left f'
    Right x -> case reify body (Right x) of
      Right (Just a) -> Right a
      Right Nothing -> retry x
      Left f' -> Left f'
    where
      retry x = case reify body (Right x) of
        Left f -> Left f
        Right Nothing -> error "compact: stuck (body returned Nothing again)"
        Right (Just a) -> Right a
  Compose f g -> Compose (compact f) g
