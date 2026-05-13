-- | File I/O via Producer and Consumer from Circuit.Channel.
--
-- Read lines from a file, write lines to a file.  The 'Consumer'
-- for writing threads @IO@ through the accumulator; the 'Producer'
-- for reading is pure.
module Circuit.IO.File
  ( -- * Reading
    readLines,
    linesProducer,
    collectAll,

    -- * Writing
    writeLines,
    linesConsumer,
  )
where

import Circuit.Channel
import Circuit.Hyper
import Data.Text hiding (cons, foldr, reverse)
import Data.Text.IO qualified as TIO
import Prelude hiding (id, (.))
import System.IO

-- $setup
-- >>> :set -XOverloadedStrings -XBlockArguments
-- >>> import Circuit.Channel
-- >>> import Circuit.IO.File
-- >>> import Data.Functor.Identity (Identity(..), runIdentity)
-- >>> import Data.Text (Text)
-- >>> import Data.Text.IO qualified as TIO
-- >>> import System.IO (hClose)
-- >>> import System.IO.Temp (withSystemTempFile)

-- ---------------------------------------------------------------------------
-- Reading (pure)
-- ---------------------------------------------------------------------------

-- | Read all lines from a file, returning them in order.
--
-- >>> withSystemTempFile "test.txt" $ \fp h -> TIO.hPutStrLn h "hello" >> TIO.hPutStrLn h "world" >> hClose h >> readLines fp
-- ["hello","world"]
readLines :: FilePath -> IO [Text]
readLines fp = withFile fp ReadMode $ \h ->
  let go acc = do
        done <- hIsEOF h
        if done
          then pure (reverse acc)
          else do
            line <- TIO.hGetLine h
            go (line : acc)
   in go []

-- | Build a 'Producer' from a list of lines.
-- Pure — the list is already in memory.
--
-- >>> runIdentity $ glue collectAll (linesProducer ["a", "b", "c"])
-- ["a","b","c"]
linesProducer :: [Text] -> Producer (Maybe Text) [Text]
linesProducer [] = Hyper $ \_ -> []
linesProducer (x : xs) = prod (Just x) (linesProducer xs)

-- | Collect all 'Just' values, stop on 'Nothing'.
--
-- >>> runIdentity $ glue collectAll (linesProducer [])
-- []
collectAll :: Consumer (Maybe Text) [Text]
collectAll = cons step (Hyper $ \_ -> \_ -> [])
  where
    step acc mx = case mx of
      Just x -> x : acc
      Nothing -> acc

-- ---------------------------------------------------------------------------
-- Writing (IO)
-- ---------------------------------------------------------------------------

-- | Write lines to a file, one per line.
--
-- >>> withSystemTempFile "test.txt" $ \fp h -> hClose h >> writeLines fp ["a", "b", "c"] >> readLines fp
-- ["a","b","c"]
writeLines :: FilePath -> [Text] -> IO ()
writeLines fp lines' = withFile fp WriteMode $ \h ->
  mapM_ (TIO.hPutStrLn h) lines'

-- | Build a 'Consumer' that writes each 'Text' as a line.
-- Uses @IO@ as the accumulator type — each write is an effect.
--
-- Use 'glue' to feed a 'Producer' into it.  The result is @IO ()@.
linesConsumer :: Handle -> Consumer Text (IO ())
linesConsumer h = cons step (Hyper $ \_ -> \_ -> pure ())
  where
    step acc line = acc >> TIO.hPutStrLn h line
