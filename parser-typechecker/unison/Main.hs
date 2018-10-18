{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}

module Main where

import           Data.Char                        (toLower)
import           System.IO                        (BufferMode (NoBuffering),
                                                   hSetBuffering, stdout)
import qualified Unison.Codebase.CommandLine      as CommandLine
import qualified Unison.Codebase.FileCodebase     as FileCodebase
import           Unison.Codebase.Runtime.JVM      (javaRuntime)
import qualified Unison.Codebase.Serialization    as S
import           Unison.Codebase.Serialization.V0 (formatSymbol)
import           Unison.Parser                    (Ann (External))
import           Unison.Symbol                    (Symbol)

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering -- cool
  let codebasePath = ".unison"
      initialBranchName = "master"
      scratchFilePath = "."
      launch = CommandLine.main scratchFilePath initialBranchName
        (javaRuntime @Symbol 42441)
        (FileCodebase.codebase1 External formatSymbol formatAnn codebasePath)

  exists <- FileCodebase.exists codebasePath
  case exists of
    True -> launch
    False -> do
      putStr "I can't find a Unison codebase here, would you like to create one? [y/n] "
      line <- getLine
      case words (map toLower line) of
        ('y':_):_ -> FileCodebase.initialize codebasePath *> launch
        _         -> pure ()

formatAnn :: S.Format Ann
formatAnn = S.Format (pure External) (\_ -> pure ())