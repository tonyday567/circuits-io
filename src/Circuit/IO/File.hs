-- | File I/O via Producer and Consumer from Circuit.Channel.
--
-- Read lines from a file, write lines to a file.  The 'Consumer'
-- for writing uses @IO@ as its monad; the 'Producer' for reading
-- is pure (@Identity@).
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
import Data.Functor.Identity
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
-- Pure (@Identity@ monad) — the list is already in memory.
--
-- >>> runIdentity $ glue collectAll (linesProducer ["a", "b", "c"])
-- ["a","b","c"]
linesProducer :: [Text] -> Producer Identity [Text] (Maybe Text)
linesProducer = foldr (\line p -> prod (Just line) p) (prod Nothing (yield []))

-- | Collect all 'Just' values, stop on 'Nothing'.
--
-- >>> runIdentity $ glue collectAll (linesProducer [])
-- []
collectAll :: Consumer Identity [Text] (Maybe Text)
collectAll = go
  where
    go = cons step go
    step mx acc = case mx of
      Just x  -> fmap (x :) acc
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
-- Uses @IO@ monad — each write is an effect.
--
-- Use 'glue' to feed a 'Producer' into it. The result is @IO ()@.
linesConsumer :: Handle -> Consumer IO () Text
linesConsumer h = cons step (accept ())
  where
    step line acc = acc >> TIO.hPutStrLn h line
