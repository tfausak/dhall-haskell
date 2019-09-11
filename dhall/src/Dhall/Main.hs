{-| This module contains the top-level entrypoint and options parsing for the
    @dhall@ executable
-}

{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Dhall.Main
    ( -- * Options
      Options(..)
    , Mode(..)
    , parseOptions
    , parserInfoOptions

      -- * Execution
    , command
    , main
    ) where

import Control.Applicative (optional, (<|>))
import Control.Exception (Handler(..), SomeException)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Text.Prettyprint.Doc (Doc, Pretty)
import Data.Version (showVersion)
import Dhall.Core (Expr(Annot), Import, pretty)
import Dhall.Freeze (Intent(..), Scope(..))
import Dhall.Import (Imported(..), Depends(..), SemanticCacheMode(..))
import Dhall.Parser (Src)
import Dhall.Pretty (Ann, CharacterSet(..), annToAnsiStyle, layoutOpts)
import Dhall.TypeCheck (DetailedTypeError(..), TypeError, X)
import Options.Applicative (Parser, ParserInfo)
import System.Exit (ExitCode, exitFailure)
import System.IO (Handle)
import Text.Dot ((.->.))

import qualified Codec.CBOR.JSON
import qualified Codec.CBOR.Read
import qualified Codec.CBOR.Write
import qualified Codec.Serialise
import qualified Control.Exception
import qualified Control.Monad.Trans.State.Strict          as State
import qualified Data.Aeson
import qualified Data.Aeson.Encode.Pretty
import qualified Data.ByteString.Lazy
import qualified Data.ByteString.Lazy.Char8
import qualified Data.Text
import qualified Data.Text.IO
import qualified Data.Text.Prettyprint.Doc                 as Pretty
import qualified Data.Text.Prettyprint.Doc.Render.Terminal as Pretty
import qualified Dhall
import qualified Dhall.Binary
import qualified Dhall.Core
import qualified Dhall.Diff
import qualified Dhall.Format
import qualified Dhall.Freeze
import qualified Dhall.Hash
import qualified Dhall.Import
import qualified Dhall.Import.Types
import qualified Dhall.Lint
import qualified Dhall.Parser
import qualified Dhall.Pretty
import qualified Dhall.Repl
import qualified Dhall.TypeCheck
import qualified GHC.IO.Encoding
import qualified Options.Applicative
import qualified Paths_dhall as Meta
import qualified System.Console.ANSI
import qualified System.Exit                               as Exit
import qualified System.IO
import qualified System.FilePath
import qualified Text.Dot
import qualified Data.Map

-- | Top-level program options
data Options = Options
    { mode            :: Mode
    , explain         :: Bool
    , plain           :: Bool
    , ascii           :: Bool
    }

-- | The subcommands for the @dhall@ executable
data Mode
    = Default
          { file :: Maybe FilePath
          , annotate :: Bool
          , alpha :: Bool
          , semanticCacheMode :: SemanticCacheMode
          }
    | Version
    | Resolve { file :: Maybe FilePath, resolveMode :: Maybe ResolveMode }
    | Type { file :: Maybe FilePath }
    | Normalize { file :: Maybe FilePath, alpha :: Bool }
    | Repl
    | Format { formatMode :: Dhall.Format.FormatMode }
    | Freeze { inplace :: Maybe FilePath, all_ :: Bool, cache :: Bool }
    | Hash
    | Diff { expr1 :: Text, expr2 :: Text }
    | Lint { inplace :: Maybe FilePath }
    | Encode { file :: Maybe FilePath, json :: Bool }
    | Decode { file :: Maybe FilePath, json :: Bool }
    | Text { file :: Maybe FilePath }

data ResolveMode
    = Dot
    | ListTransitiveDependencies
    | ListImmediateDependencies


-- | `Parser` for the `Options` type
parseOptions :: Parser Options
parseOptions =
        Options
    <$> parseMode
    <*> switch "explain" "Explain error messages in more detail"
    <*> switch "plain" "Disable syntax highlighting"
    <*> switch "ascii" "Format code using only ASCII syntax"
  where
    switch name description =
        Options.Applicative.switch
            (   Options.Applicative.long name
            <>  Options.Applicative.help description
            )

subcommand :: String -> String -> Parser a -> Parser a
subcommand name description parser =
    Options.Applicative.hsubparser
        (   Options.Applicative.command name parserInfo
        <>  Options.Applicative.metavar name
        )
  where
    parserInfo =
        Options.Applicative.info parser
            (   Options.Applicative.fullDesc
            <>  Options.Applicative.progDesc description
            )

parseMode :: Parser Mode
parseMode =
        subcommand
            "version"
            "Display version"
            (pure Version)
    <|> subcommand
            "resolve"
            "Resolve an expression's imports"
            (Resolve <$> optional parseFile <*> parseResolveMode)
    <|> subcommand
            "type"
            "Infer an expression's type"
            (Type <$> optional parseFile)
    <|> subcommand
            "normalize"
            "Normalize an expression"
            (Normalize <$> optional parseFile <*> parseAlpha)
    <|> subcommand
            "repl"
            "Interpret expressions in a REPL"
            (pure Repl)
    <|> subcommand
            "diff"
            "Render the difference between the normal form of two expressions"
            (Diff <$> argument "expr1" <*> argument "expr2")
    <|> subcommand
            "hash"
            "Compute semantic hashes for Dhall expressions"
            (pure Hash)
    <|> subcommand
            "lint"
            "Improve Dhall code by using newer language features and removing dead code"
            (Lint <$> optional parseInplace)
    <|> subcommand
            "format"
            "Standard code formatter for the Dhall language"
            (Format <$> parseFormatMode)
    <|> subcommand
            "freeze"
            "Add integrity checks to remote import statements of an expression"
            (Freeze <$> optional parseInplace <*> parseAllFlag <*> parseCacheFlag)
    <|> subcommand
            "encode"
            "Encode a Dhall expression to binary"
            (Encode <$> optional parseFile <*> parseJSONFlag)
    <|> subcommand
            "decode"
            "Decode a Dhall expression from binary"
            (Decode <$> optional parseFile <*> parseJSONFlag)
    <|> subcommand
            "text"
            "Render a Dhall expression that evaluates to a Text literal"
            (Text <$> optional parseFile)
    <|> (Default <$> optional parseFile <*> parseAnnotate <*> parseAlpha <*> parseSemanticCacheMode)
  where
    argument =
            fmap Data.Text.pack
        .   Options.Applicative.strArgument
        .   Options.Applicative.metavar

    parseFile =
        Options.Applicative.strOption
            (   Options.Applicative.long "file"
            <>  Options.Applicative.help "Read expression from a file instead of standard input"
            <>  Options.Applicative.metavar "FILE"
            )

    parseAlpha =
        Options.Applicative.switch
            (   Options.Applicative.long "alpha"
            <>  Options.Applicative.help "α-normalize expression"
            )

    parseAnnotate =
        Options.Applicative.switch
            (   Options.Applicative.long "annotate"
            <>  Options.Applicative.help "Add a type annotation to the output"
            )

    parseSemanticCacheMode =
        Options.Applicative.flag
            UseSemanticCache
            IgnoreSemanticCache
            (   Options.Applicative.long "no-cache"
            <>  Options.Applicative.help
                  "Handle protected imports as if the cache was empty"
            )

    parseResolveMode =
          Options.Applicative.flag' (Just Dot)
              (   Options.Applicative.long "dot"
              <>  Options.Applicative.help
                    "Output import dependency graph in dot format"
              )
        <|>
          Options.Applicative.flag' (Just ListImmediateDependencies)
              (   Options.Applicative.long "immediate-dependencies"
              <>  Options.Applicative.help
                    "List immediate import dependencies"
              )
        <|>
          Options.Applicative.flag' (Just ListTransitiveDependencies)
              (   Options.Applicative.long "transitive-dependencies"
              <>  Options.Applicative.help
                    "List transitive import dependencies"
              )
        <|> pure Nothing

    parseInplace =
        Options.Applicative.strOption
        (   Options.Applicative.long "inplace"
        <>  Options.Applicative.help "Modify the specified file in-place"
        <>  Options.Applicative.metavar "FILE"
        )

    parseJSONFlag =
        Options.Applicative.switch
        (   Options.Applicative.long "json"
        <>  Options.Applicative.help "Use JSON representation of CBOR"
        )

    parseAllFlag =
        Options.Applicative.switch
        (   Options.Applicative.long "all"
        <>  Options.Applicative.help "Add integrity checks to all imports (not just remote imports)"
        )

    parseCacheFlag =
        Options.Applicative.switch
        (   Options.Applicative.long "cache"
        <>  Options.Applicative.help "Add fallback unprotected imports when using integrity checks purely for caching purposes"
        )

    parseCheck =
        Options.Applicative.switch
        (   Options.Applicative.long "check"
        <>  Options.Applicative.help "Only check if the input is formatted"
        )

    parseFormatMode = adapt <$> parseCheck <*> optional parseInplace
      where
        adapt True  path    = Dhall.Format.Check {..}
        adapt False inplace = Dhall.Format.Modify {..}

getExpression :: Maybe FilePath -> IO (Expr Src Import)
getExpression maybeFile = do
    inText <- do
        case maybeFile of
            Just file -> Data.Text.IO.readFile file
            Nothing   -> Data.Text.IO.getContents

    Dhall.Core.throws (Dhall.Parser.exprFromText "(stdin)" inText)

-- | `ParserInfo` for the `Options` type
parserInfoOptions :: ParserInfo Options
parserInfoOptions =
    Options.Applicative.info
        (Options.Applicative.helper <*> parseOptions)
        (   Options.Applicative.progDesc "Interpreter for the Dhall language"
        <>  Options.Applicative.fullDesc
        )

-- | Run the command specified by the `Options` type
command :: Options -> IO ()
command (Options {..}) = do
    let characterSet = case ascii of
            True  -> ASCII
            False -> Unicode

    GHC.IO.Encoding.setLocaleEncoding System.IO.utf8

    let rootDirectory = \case
            Just f   -> System.FilePath.takeDirectory f
            Nothing  -> "."

    let toStatus = Dhall.Import.emptyStatus . rootDirectory

    let handle io =
            Control.Exception.catches io
                [ Handler handleTypeError
                , Handler handleImported
                , Handler handleExitCode
                ]
          where
            handleAll e = do
                let string = show (e :: SomeException)

                if not (null string)
                    then System.IO.hPutStrLn System.IO.stderr string
                    else return ()

                System.Exit.exitFailure

            handleTypeError e = Control.Exception.handle handleAll $ do
                let _ = e :: TypeError Src X
                System.IO.hPutStrLn System.IO.stderr ""
                if explain
                    then Control.Exception.throwIO (DetailedTypeError e)
                    else do
                        Data.Text.IO.hPutStrLn System.IO.stderr "\ESC[2mUse \"dhall --explain\" for detailed errors\ESC[0m"
                        Control.Exception.throwIO e

            handleImported (Imported ps e) = Control.Exception.handle handleAll $ do
                let _ = e :: TypeError Src X
                System.IO.hPutStrLn System.IO.stderr ""
                if explain
                    then Control.Exception.throwIO (Imported ps (DetailedTypeError e))
                    else do
                        Data.Text.IO.hPutStrLn System.IO.stderr "\ESC[2mUse \"dhall --explain\" for detailed errors\ESC[0m"
                        Control.Exception.throwIO (Imported ps e)

            handleExitCode e = do
                Control.Exception.throwIO (e :: ExitCode)

    let renderDoc :: Handle -> Doc Ann -> IO ()
        renderDoc h doc = do
            let stream = Pretty.layoutSmart layoutOpts doc

            supportsANSI <- System.Console.ANSI.hSupportsANSI h
            let ansiStream =
                    if supportsANSI && not plain
                    then fmap annToAnsiStyle stream
                    else Pretty.unAnnotateS stream

            Pretty.renderIO h ansiStream
            Data.Text.IO.hPutStrLn h ""

    let render :: Pretty a => Handle -> Expr s a -> IO ()
        render h expression = do
            let doc = Dhall.Pretty.prettyCharacterSet characterSet expression

            renderDoc h doc

    handle $ case mode of
        Version -> do
            putStrLn (showVersion Meta.version)

        Default {..} -> do
            expression <- getExpression file

            resolvedExpression <-
                Dhall.Import.loadRelativeTo (rootDirectory file) semanticCacheMode expression

            inferredType <- Dhall.Core.throws (Dhall.TypeCheck.typeOf resolvedExpression)

            let normalizedExpression = Dhall.Core.normalize resolvedExpression

            let alphaNormalizedExpression =
                    if alpha
                    then Dhall.Core.alphaNormalize normalizedExpression
                    else normalizedExpression

            let annotatedExpression =
                    if annotate
                        then Annot alphaNormalizedExpression inferredType
                        else alphaNormalizedExpression

            render System.IO.stdout annotatedExpression

        Resolve { resolveMode = Just Dot, ..} -> do
            expression <- getExpression file

            (Dhall.Import.Types.Status { _graph, _stack }) <-
                State.execStateT (Dhall.Import.loadWith expression) (toStatus file)

            let (rootImport :| _) = _stack
                imports = rootImport : map parent _graph ++ map child _graph
                importIds = Data.Map.fromList (zip imports [Text.Dot.userNodeId i | i <- [0..]])

            let dotNode (i, nodeId) =
                    Text.Dot.userNode
                        nodeId
                        [ ("label", Data.Text.unpack $ pretty i)
                        , ("shape", "box")
                        , ("style", "rounded")
                        ]

            let dotEdge (Depends parent child) =
                    case (Data.Map.lookup parent importIds, Data.Map.lookup child importIds) of
                        (Just from, Just to) -> from .->. to
                        _                    -> pure ()

            let dot = do Text.Dot.attribute ("rankdir", "LR")
                         mapM_ dotNode (Data.Map.assocs importIds)
                         mapM_ dotEdge _graph

            putStr . ("strict " <>) . Text.Dot.showDot $ dot

        Resolve { resolveMode = Just ListImmediateDependencies, ..} -> do
            expression <- getExpression file

            mapM_ (print
                        . Pretty.pretty
                        . Dhall.Core.importHashed) expression

        Resolve { resolveMode = Just ListTransitiveDependencies, ..} -> do
            expression <- getExpression file

            (Dhall.Import.Types.Status { _cache }) <-
                State.execStateT (Dhall.Import.loadWith expression) (toStatus file)

            mapM_ print
                 .   fmap (   Pretty.pretty
                          .   Dhall.Core.importType
                          .   Dhall.Core.importHashed
                          .   Dhall.Import.chainedImport )
                 .   Data.Map.keys
                 $   _cache

        Resolve { resolveMode = Nothing, ..} -> do
            expression <- getExpression file

            resolvedExpression <-
                Dhall.Import.loadRelativeTo (rootDirectory file) UseSemanticCache expression

            render System.IO.stdout resolvedExpression

        Normalize {..} -> do
            expression <- getExpression file

            resolvedExpression <- Dhall.Import.assertNoImports expression

            _ <- Dhall.Core.throws (Dhall.TypeCheck.typeOf resolvedExpression)

            let normalizedExpression = Dhall.Core.normalize resolvedExpression

            let alphaNormalizedExpression =
                    if alpha
                    then Dhall.Core.alphaNormalize normalizedExpression
                    else normalizedExpression

            render System.IO.stdout alphaNormalizedExpression

        Type {..} -> do
            expression <- getExpression file

            resolvedExpression <-
                Dhall.Import.loadRelativeTo (rootDirectory file) UseSemanticCache expression

            inferredType <- Dhall.Core.throws (Dhall.TypeCheck.typeOf resolvedExpression)

            render System.IO.stdout (Dhall.Core.normalize inferredType)

        Repl -> do
            Dhall.Repl.repl characterSet explain

        Diff {..} -> do
            expression1 <- Dhall.inputExpr expr1

            expression2 <- Dhall.inputExpr expr2

            let diff = Dhall.Diff.diffNormalized expression1 expression2

            renderDoc System.IO.stdout (Dhall.Diff.doc diff)

            if Dhall.Diff.same diff
                then return ()
                else Exit.exitFailure

        Format {..} -> do
            Dhall.Format.format (Dhall.Format.Format {..})

        Freeze {..} -> do
            let scope = if all_ then AllImports else OnlyRemoteImports

            let intent = if cache then Cache else Secure

            Dhall.Freeze.freeze inplace scope intent characterSet

        Hash -> do
            Dhall.Hash.hash

        Lint {..} -> do
            case inplace of
                Just file -> do
                    text <- Data.Text.IO.readFile file

                    (header, expression) <- Dhall.Core.throws (Dhall.Parser.exprAndHeaderFromText file text)

                    let lintedExpression = Dhall.Lint.lint expression

                    let doc =   Pretty.pretty header
                            <>  Dhall.Pretty.prettyCharacterSet characterSet lintedExpression

                    System.IO.withFile file System.IO.WriteMode (\h -> do
                        renderDoc h doc )

                Nothing -> do
                    text <- Data.Text.IO.getContents

                    (header, expression) <- Dhall.Core.throws (Dhall.Parser.exprAndHeaderFromText "(stdin)" text)

                    let lintedExpression = Dhall.Lint.lint expression

                    let doc =   Pretty.pretty header
                            <>  Dhall.Pretty.prettyCharacterSet characterSet lintedExpression

                    renderDoc System.IO.stdout doc

        Encode {..} -> do
            expression <- getExpression file

            let term = Dhall.Binary.encodeExpression expression

            let bytes = Codec.Serialise.serialise term

            if json
                then do
                    let decoder = Codec.CBOR.JSON.decodeValue False

                    (_, value) <- Dhall.Core.throws (Codec.CBOR.Read.deserialiseFromBytes decoder bytes)

                    let jsonBytes = Data.Aeson.Encode.Pretty.encodePretty value

                    Data.ByteString.Lazy.Char8.putStrLn jsonBytes

                else do
                    Data.ByteString.Lazy.putStr bytes

        Decode {..} -> do
            bytes <- do
                case file of
                    Just f  -> Data.ByteString.Lazy.readFile f
                    Nothing -> Data.ByteString.Lazy.getContents

            term <- do
                if json
                    then do
                        value <- case Data.Aeson.eitherDecode' bytes of
                            Left  string -> fail string
                            Right value  -> return value

                        let encoding = Codec.CBOR.JSON.encodeValue value

                        let cborBytes = Codec.CBOR.Write.toLazyByteString encoding
                        Dhall.Core.throws (Codec.Serialise.deserialiseOrFail cborBytes)
                    else do
                        Dhall.Core.throws (Codec.Serialise.deserialiseOrFail bytes)

            expression <- Dhall.Core.throws (Dhall.Binary.decodeExpression term)
                :: IO (Expr Src Import)

            let doc = Dhall.Pretty.prettyCharacterSet characterSet expression

            renderDoc System.IO.stdout doc

        Text {..} -> do
            expression <- getExpression file

            resolvedExpression <-
                Dhall.Import.loadRelativeTo (rootDirectory file) UseSemanticCache expression

            _ <- Dhall.Core.throws (Dhall.TypeCheck.typeOf (Annot resolvedExpression Dhall.Core.Text))

            let normalizedExpression = Dhall.Core.normalize resolvedExpression

            case normalizedExpression of
                Dhall.Core.TextLit (Dhall.Core.Chunks [] text) -> do
                    Data.Text.IO.putStr text
                _ -> do
                    let invalidTypeExpected :: Expr X X
                        invalidTypeExpected = Dhall.Core.Text

                    let invalidTypeExpression :: Expr X X
                        invalidTypeExpression = normalizedExpression

                    Control.Exception.throwIO (Dhall.InvalidType {..})

-- | Entry point for the @dhall@ executable
main :: IO ()
main = do
    options <- Options.Applicative.execParser parserInfoOptions
    command options
