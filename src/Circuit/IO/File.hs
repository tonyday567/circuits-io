-- | File I/O via Producer and Consumer from Circuit.Channel.
--
-- Read lines from a file, write lines to a file.  Producers and Consumers
-- are built from lists; the IO happens in 'readLines' and 'writeLines'.
module Circuit.IO.File
  ( -- * Reading
    readLines,
    linesProducer,

    -- * Writing
    writeLines,
    linesConsumer,

    -- * Helpers
    collectAll,
  )
where

import Circuit.Channel
  ( Consumer,
    Producer,
    accept,
    cons,
    prod,
    yield,
  )
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Prelude hiding (id, (.))
import System.IO (Handle, IOMode (ReadMode, WriteMode), hIsEOF, withFile)

-- $setup
-- >>> :set -XOverloadedStrings -XBlockArguments -XNondecreasingIndentation
-- >>> import Circuit.Channel
-- >>> import Circuit.IO.File
-- >>> import Data.Text (Text)
-- >>> import Data.Text.IO qualified as TIO
-- >>> import System.IO (hClose)
-- >>> import System.IO.Temp (withSystemTempFile)

-- ---------------------------------------------------------------------------
-- Reading
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
-- Each @Just line@ is one message, @Nothing@ signals end.
--
-- >>> glue collectAll (linesProducer ["a", "b", "c"])
-- ["a","b","c"]
linesProducer :: [Text] -> Producer (Maybe Text) [Text]
linesProducer = foldr (\line p -> prod (Just line) p) (prod Nothing (yield []))

-- | Collect all 'Just' values from a producer, stop on 'Nothing'.
--
-- >>> glue collectAll (linesProducer [])
-- []
collectAll :: Consumer (Maybe a) [a]
collectAll = go
  where
    go = cons step go
    step mx acc = case mx of
      Just x  -> x : acc
      Nothing -> acc

-- ---------------------------------------------------------------------------
-- Writing
-- ---------------------------------------------------------------------------

-- | Write lines to a file, one per line.
--
-- >>> withSystemTempFile "test.txt" $ \fp h -> hClose h >> writeLines fp ["a", "b", "c"] >> readLines fp
-- ["a","b","c"]
writeLines :: FilePath -> [Text] -> IO ()
writeLines fp lines' = withFile fp WriteMode $ \h ->
  mapM_ (TIO.hPutStrLn h) lines'

-- | Build a 'Consumer' that writes each 'Text' as a line to a 'Handle'.
-- Use with 'glue' to feed a 'Producer' into it.
linesConsumer :: Handle -> Consumer Text ()
linesConsumer h = cons step (accept ())
  where
    step line () = TIO.hPutStrLn h line `seq` ()
