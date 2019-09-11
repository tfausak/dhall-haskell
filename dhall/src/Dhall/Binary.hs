{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE OverloadedStrings  #-}

{-| This module contains logic for converting Dhall expressions to and from
    CBOR expressions which can in turn be converted to and from a binary
    representation
-}

module Dhall.Binary
    ( -- * Standard versions
      StandardVersion(..)
    , renderStandardVersion

    -- * Encoding and decoding
    , ToTerm(..)
    , FromTerm(..)
    , encodeExpression
    , decodeExpression

    -- * Exceptions
    , DecodingFailure(..)
    ) where

import Codec.CBOR.Term (Term(..))
import Control.Applicative (empty, (<|>))
import Control.Exception (Exception)
import Dhall.Core
    ( Binding(..)
    , Chunks(..)
    , Const(..)
    , Directory(..)
    , Expr(..)
    , File(..)
    , FilePrefix(..)
    , Import(..)
    , ImportHashed(..)
    , ImportMode(..)
    , ImportType(..)
    , MultiLet(..)
    , Scheme(..)
    , URL(..)
    , Var(..)
    )

import Data.Foldable (toList)
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Void (Void, absurd)
import GHC.Float (double2Float, float2Double)

import qualified Crypto.Hash
import qualified Control.Monad       as Monad
import qualified Data.ByteArray
import qualified Data.ByteString
import qualified Data.Sequence
import qualified Dhall.Core
import qualified Dhall.Map
import qualified Dhall.Set

-- | Supported version strings
data StandardVersion
    = NoVersion
    -- ^ No version string
    | V_5_0_0
    -- ^ Version "5.0.0"
    | V_4_0_0
    -- ^ Version "4.0.0"
    | V_3_0_0
    -- ^ Version "3.0.0"
    | V_2_0_0
    -- ^ Version "2.0.0"
    | V_1_0_0
    -- ^ Version "1.0.0"
    deriving (Enum, Bounded)

renderStandardVersion :: StandardVersion -> Text
renderStandardVersion NoVersion = "none"
renderStandardVersion V_1_0_0   = "1.0.0"
renderStandardVersion V_2_0_0   = "2.0.0"
renderStandardVersion V_3_0_0   = "3.0.0"
renderStandardVersion V_4_0_0   = "4.0.0"
renderStandardVersion V_5_0_0   = "5.0.0"

{-| Convert a function applied to multiple arguments to the base function and
    the list of arguments
-}
unApply :: Expr s a -> (Expr s a, [Expr s a])
unApply e₀ = (baseFunction₀, diffArguments₀ [])
  where
    ~(baseFunction₀, diffArguments₀) = go e₀

    go (App f a) = (baseFunction, diffArguments . (a :))
      where
        ~(baseFunction, diffArguments) = go f

    go (Note _ e) = go e

    go baseFunction = (baseFunction, id)

-- | Types that can be encoded as a CBOR `Term`
class ToTerm a where
    encode :: a -> Term

instance ToTerm a => ToTerm (Expr Void a) where
    encode (Var (V "_" n)) =
        TInt n
    encode (Var (V x n)) =
        TList [ TString x, TInt n ]
    encode NaturalBuild =
        TString "Natural/build"
    encode NaturalFold =
        TString "Natural/fold"
    encode NaturalIsZero =
        TString "Natural/isZero"
    encode NaturalEven =
        TString "Natural/even"
    encode NaturalOdd =
        TString "Natural/odd"
    encode NaturalToInteger =
        TString "Natural/toInteger"
    encode NaturalShow =
        TString "Natural/show"
    encode NaturalSubtract =
        TString "Natural/subtract"
    encode IntegerToDouble =
        TString "Integer/toDouble"
    encode IntegerShow =
        TString "Integer/show"
    encode DoubleShow =
        TString "Double/show"
    encode ListBuild =
        TString "List/build"
    encode ListFold =
        TString "List/fold"
    encode ListLength =
        TString "List/length"
    encode ListHead =
        TString "List/head"
    encode ListLast =
        TString "List/last"
    encode ListIndexed =
        TString "List/indexed"
    encode ListReverse =
        TString "List/reverse"
    encode OptionalFold =
        TString "Optional/fold"
    encode OptionalBuild =
        TString "Optional/build"
    encode Bool =
        TString "Bool"
    encode Optional =
        TString "Optional"
    encode None =
        TString "None"
    encode Natural =
        TString "Natural"
    encode Integer =
        TString "Integer"
    encode Double =
        TString "Double"
    encode Text =
        TString "Text"
    encode TextShow =
        TString "Text/show"
    encode List =
        TString "List"
    encode (Const Type) =
        TString "Type"
    encode (Const Kind) =
        TString "Kind"
    encode (Const Sort) =
        TString "Sort"
    encode e@(App _ _) =
        TList ([ TInt 0, f₁ ] ++ map encode arguments)
      where
        (f₀, arguments) = unApply e

        f₁ = encode f₀
    encode (Lam "_" _A₀ b₀) =
        TList [ TInt 1, _A₁, b₁ ]
      where
        _A₁ = encode _A₀
        b₁  = encode b₀
    encode (Lam x _A₀ b₀) =
        TList [ TInt 1, TString x, _A₁, b₁ ]
      where
        _A₁ = encode _A₀
        b₁  = encode b₀
    encode (Pi "_" _A₀ _B₀) =
        TList [ TInt 2, _A₁, _B₁ ]
      where
        _A₁ = encode _A₀
        _B₁ = encode _B₀
    encode (Pi x _A₀ _B₀) =
        TList [ TInt 2, TString x, _A₁, _B₁ ]
      where
        _A₁ = encode _A₀
        _B₁ = encode _B₀
    encode (BoolOr l₀ r₀) =
        TList [ TInt 3, TInt 0, l₁, r₁ ]
      where
        l₁ = encode l₀
        r₁ = encode r₀
    encode (BoolAnd l₀ r₀) =
        TList [ TInt 3, TInt 1, l₁, r₁ ]
      where
        l₁ = encode l₀
        r₁ = encode r₀
    encode (BoolEQ l₀ r₀) =
        TList [ TInt 3, TInt 2, l₁, r₁ ]
      where
        l₁ = encode l₀
        r₁ = encode r₀
    encode (BoolNE l₀ r₀) =
        TList [ TInt 3, TInt 3, l₁, r₁ ]
      where
        l₁ = encode l₀
        r₁ = encode r₀
    encode (NaturalPlus l₀ r₀) =
        TList [ TInt 3, TInt 4, l₁, r₁ ]
      where
        l₁ = encode l₀
        r₁ = encode r₀
    encode (NaturalTimes l₀ r₀) =
        TList [ TInt 3, TInt 5, l₁, r₁ ]
      where
        l₁ = encode l₀
        r₁ = encode r₀
    encode (TextAppend l₀ r₀) =
        TList [ TInt 3, TInt 6, l₁, r₁ ]
      where
        l₁ = encode l₀
        r₁ = encode r₀
    encode (ListAppend l₀ r₀) =
        TList [ TInt 3, TInt 7, l₁, r₁ ]
      where
        l₁ = encode l₀
        r₁ = encode r₀
    encode (Combine l₀ r₀) =
        TList [ TInt 3, TInt 8, l₁, r₁ ]
      where
        l₁ = encode l₀
        r₁ = encode r₀
    encode (Prefer l₀ r₀) =
        TList [ TInt 3, TInt 9, l₁, r₁ ]
      where
        l₁ = encode l₀
        r₁ = encode r₀
    encode (CombineTypes l₀ r₀) =
        TList [ TInt 3, TInt 10, l₁, r₁ ]
      where
        l₁ = encode l₀
        r₁ = encode r₀
    encode (ImportAlt l₀ r₀) =
        TList [ TInt 3, TInt 11, l₁, r₁ ]
      where
        l₁ = encode l₀
        r₁ = encode r₀
    encode (Equivalent l₀ r₀) =
        TList [ TInt 3, TInt 12, l₁, r₁ ]
      where
        l₁ = encode l₀
        r₁ = encode r₀
    encode (ListLit _T₀ xs₀)
        | null xs₀  = TList [ TInt label, _T₁ ]
        | otherwise = TList ([ TInt 4, TNull ] ++ xs₁)
      where
        (label, _T₁) = case _T₀ of
            Nothing           -> (4 , TNull)
            Just (App List t) -> (4 , encode t)
            Just t            -> (28, encode t)

        xs₁ = map encode (Data.Foldable.toList xs₀)
    encode (Some t₀) =
        TList [ TInt 5, TNull, t₁ ]
      where
        t₁ = encode t₀
    encode (Merge t₀ u₀ Nothing) =
        TList [ TInt 6, t₁, u₁ ]
      where
        t₁ = encode t₀
        u₁ = encode u₀
    encode (Merge t₀ u₀ (Just _T₀)) =
        TList [ TInt 6, t₁, u₁, _T₁ ]
      where
        t₁  = encode t₀
        u₁  = encode u₀
        _T₁ = encode _T₀
    encode (Record xTs₀) =
        TList [ TInt 7, TMap xTs₁ ]
      where
        xTs₁ = do
            (x₀, _T₀) <- Dhall.Map.toList (Dhall.Map.sort xTs₀)
            let x₁  = TString x₀
            let _T₁ = encode _T₀
            return (x₁, _T₁)
    encode (RecordLit xts₀) =
        TList [ TInt 8, TMap xts₁ ]
      where
        xts₁ = do
            (x₀, t₀) <- Dhall.Map.toList (Dhall.Map.sort xts₀)
            let x₁ = TString x₀
            let t₁ = encode t₀
            return (x₁, t₁)
    encode (Field t₀ x) =
        TList [ TInt 9, t₁, TString x ]
      where
        t₁ = encode t₀
    encode (Project t₀ (Left xs₀)) =
        TList ([ TInt 10, t₁ ] ++ xs₁)
      where
        t₁  = encode t₀
        xs₁ = map TString (Dhall.Set.toList xs₀)
    encode (Project t₀ (Right _T₀)) =
        TList [ TInt 10, t₁, TList [ _T₁ ] ]
      where
        _T₁ = encode _T₀
        t₁  = encode t₀
    encode (Union xTs₀) =
        TList [ TInt 11, TMap xTs₁ ]
      where
        xTs₁ = do
            (x₀, mT₀) <- Dhall.Map.toList (Dhall.Map.sort xTs₀)

            let x₁  = TString x₀

            let _T₁ = case mT₀ of
                    Nothing  -> TNull
                    Just _T₀ -> encode _T₀

            return (x₁, _T₁)
    encode (BoolLit b) =
        TBool b
    encode (BoolIf t₀ l₀ r₀) =
        TList [ TInt 14, t₁, l₁, r₁ ]
      where
        t₁ = encode t₀
        l₁ = encode l₀
        r₁ = encode r₀
    encode (NaturalLit n) =
        TList [ TInt 15, TInteger (fromIntegral n) ]
    encode (IntegerLit n) =
        TList [ TInt 16, TInteger n ]
    encode (DoubleLit n64)
        -- cborg always encodes NaN as "7e00"
        | isNaN n64 = THalf n32
        | useHalf   = THalf n32
        | useFloat  = TFloat n32
        | otherwise = TDouble n64
      where
        n32      = double2Float n64
        useFloat = n64 == float2Double n32
        -- the other three cases for Half-floats are 0.0 and the infinities
        useHalf  = or $ fmap (n64 ==) [0.0, infinity, -infinity]
        infinity = 1/0 :: Double
    encode (TextLit (Chunks xys₀ z₀)) =
        TList ([ TInt 18 ] ++ xys₁ ++ [ z₁ ])
      where
        xys₁ = do
            (x₀, y₀) <- xys₀
            let x₁ = TString x₀
            let y₁ = encode y₀
            [ x₁, y₁ ]

        z₁ = TString z₀
    encode (Assert t₀) =
        TList [ TInt 19, t₁ ]
      where
        t₁ = encode t₀
    encode (Embed x) =
        encode x
    encode (Let x mA a b) =
        TList ([ TInt 25 ] ++ as₁ ++ [ b₁ ])
      where
        MultiLet as₀ b₀ = Dhall.Core.multiLet x mA a b

        as₁ = do
            Binding x₀ mA₀ a₀ <- toList as₀

            let mA₁ = case mA₀ of
                    Nothing  -> TNull
                    Just _A₀ -> encode _A₀

            let a₁ = encode a₀

            [ TString x₀, mA₁, a₁ ]

        b₁ = encode b₀
    encode (Annot t₀ _T₀) =
        TList [ TInt 26, t₁, _T₁ ]
      where
        t₁  = encode t₀
        _T₁ = encode _T₀
    encode (ToMap t₀ Nothing) =
        TList [ TInt 27, t₁ ]
      where
        t₁ = encode t₀
    encode (ToMap t₀ (Just _T₀)) =
        TList [ TInt 27, t₁, _T₁ ]
      where
        t₁  = encode t₀
        _T₁ = encode _T₀
    encode (Note a _) = absurd a

instance ToTerm Import where
    encode import_ =
        case importType of
            Remote (URL { scheme = scheme₀, ..}) ->
                TList
                    (   prefix
                    ++  [ TInt scheme₁, using, TString authority ]
                    ++  map TString (reverse components)
                    ++  [ TString file ]
                    ++  (case query    of Nothing -> [ TNull ]; Just q -> [ TString q ])
                    )
              where
                using = case headers of
                    Nothing ->
                        TNull
                    Just h ->
                        encodeExpression h

                scheme₁ = case scheme₀ of
                    HTTP  -> 0
                    HTTPS -> 1
                File {..} = path

                Directory {..} = directory

            Local prefix₀ path ->
                    TList
                        (   prefix
                        ++  [ TInt prefix₁ ]
                        ++  map TString components₁
                        ++  [ TString file ]
                        )
              where
                File {..} = path

                Directory {..} = directory

                prefix₁ = case prefix₀ of
                  Absolute -> 2
                  Here     -> 3
                  Parent   -> 4
                  Home     -> 5

                components₁ = reverse components

            Env x ->
                TList (prefix ++ [ TInt 6, TString x ])

            Missing ->
                TList (prefix ++ [ TInt 7 ])
      where
        prefix = [ TInt 24, h, m ]
          where
            h = case hash of
                Nothing ->
                    TNull
                Just digest ->
                    TBytes ("\x12\x20" <> Data.ByteArray.convert digest)

            m = TInt (case importMode of Code -> 0; RawText -> 1; Location -> 2;)

        Import {..} = import_

        ImportHashed {..} = importHashed

instance ToTerm Void where
    encode = absurd

-- | Types that can be decoded from a CBOR `Term`
class FromTerm a where
    decode :: Term -> Maybe a

instance FromTerm a => FromTerm (Expr s a) where
    decode (TInt n) =
        return (Var (V "_" n))
    decode (TInteger n) =
        return (Var (V "_" (fromIntegral n)))
    decode (TString "Natural/build") =
        return NaturalBuild
    decode (TString "Natural/fold") =
        return NaturalFold
    decode (TString "Natural/isZero") =
        return NaturalIsZero
    decode (TString "Natural/even") =
        return NaturalEven
    decode (TString "Natural/odd") =
        return NaturalOdd
    decode (TString "Natural/toInteger") =
        return NaturalToInteger
    decode (TString "Natural/show") =
        return NaturalShow
    decode (TString "Natural/subtract") =
        return NaturalSubtract
    decode (TString "Integer/toDouble") =
        return IntegerToDouble
    decode (TString "Integer/show") =
        return IntegerShow
    decode (TString "Double/show") =
        return DoubleShow
    decode (TString "List/build") =
        return ListBuild
    decode (TString "List/fold") =
        return ListFold
    decode (TString "List/length") =
        return ListLength
    decode (TString "List/head") =
        return ListHead
    decode (TString "List/last") =
        return ListLast
    decode (TString "List/indexed") =
        return ListIndexed
    decode (TString "List/reverse") =
        return ListReverse
    decode (TString "Optional/fold") =
        return OptionalFold
    decode (TString "Optional/build") =
        return OptionalBuild
    decode (TString "Bool") =
        return Bool
    decode (TString "Optional") =
        return Optional
    decode (TString "None") =
        return None
    decode (TString "Natural") =
        return Natural
    decode (TString "Integer") =
        return Integer
    decode (TString "Double") =
        return Double
    decode (TString "Text") =
        return Text
    decode (TString "Text/show") =
        return TextShow
    decode (TString "List") =
        return List
    decode (TString "Type") =
        return (Const Type)
    decode (TString "Kind") =
        return (Const Kind)
    decode (TString "Sort") =
        return (Const Sort)
    decode (TString "_") =
        empty
    decode (TList [ TString x, TInt n ]) = do
        Monad.guard (x /= "_")
        return (Var (V x n))
    decode (TList [ TString x, TInteger n ]) = do
        Monad.guard (x /= "_")
        return (Var (V x (fromIntegral n)))
    decode (TList (TInt 0 : f₁ : xs₁)) = do
        f₀  <- decode f₁
        xs₀ <- traverse decode xs₁
        Monad.guard (not (null xs₀))
        return (foldl App f₀ xs₀)
    decode (TList [ TInt 1, _A₁, b₁ ]) = do
        _A₀ <- decode _A₁
        b₀  <- decode b₁
        return (Lam "_" _A₀ b₀)
    decode (TList [ TInt 1, TString x, _A₁, b₁ ]) = do
        Monad.guard (x /= "_")
        _A₀ <- decode _A₁
        b₀  <- decode b₁
        return (Lam x _A₀ b₀)
    decode (TList [ TInt 2, _A₁, _B₁ ]) = do
        _A₀ <- decode _A₁
        _B₀ <- decode _B₁
        return (Pi "_" _A₀ _B₀)
    decode (TList [ TInt 2, TString x, _A₁, _B₁ ]) = do
        Monad.guard (x /= "_")
        _A₀ <- decode _A₁
        _B₀ <- decode _B₁
        return (Pi x _A₀ _B₀)
    decode (TList [ TInt 3, TInt n, l₁, r₁ ]) = do
        l₀ <- decode l₁
        r₀ <- decode r₁
        op <- case n of
                0  -> return BoolOr
                1  -> return BoolAnd
                2  -> return BoolEQ
                3  -> return BoolNE
                4  -> return NaturalPlus
                5  -> return NaturalTimes
                6  -> return TextAppend
                7  -> return ListAppend
                8  -> return Combine
                9  -> return Prefer
                10 -> return CombineTypes
                11 -> return ImportAlt
                12 -> return Equivalent
                _  -> empty
        return (op l₀ r₀)
    decode (TList [ TInt 4, _T₁ ]) = do
        _T₀ <- decode _T₁
        return (ListLit (Just (App List _T₀)) empty)
    decode (TList (TInt 4 : TNull : xs₁ )) = do
        xs₀ <- traverse decode xs₁
        return (ListLit Nothing (Data.Sequence.fromList xs₀))
    decode (TList [ TInt 5, TNull, t₁ ]) = do
        t₀ <- decode t₁
        return (Some t₀)
    decode (TList [ TInt 6, t₁, u₁ ]) = do
        t₀ <- decode t₁
        u₀ <- decode u₁
        return (Merge t₀ u₀ Nothing)
    decode (TList [ TInt 6, t₁, u₁, _T₁ ]) = do
        t₀  <- decode t₁
        u₀  <- decode u₁
        _T₀ <- decode _T₁
        return (Merge t₀ u₀ (Just _T₀))
    decode (TList [ TInt 7, TMap xTs₁ ]) = do
        let process (TString x, _T₁) = do
                _T₀ <- decode _T₁

                return (x, _T₀)
            process _ =
                empty

        xTs₀ <- traverse process xTs₁

        return (Record (Dhall.Map.fromList xTs₀))
    decode (TList [ TInt 8, TMap xts₁ ]) = do
        let process (TString x, t₁) = do
               t₀ <- decode t₁

               return (x, t₀)
            process _ =
                empty

        xts₀ <- traverse process xts₁

        return (RecordLit (Dhall.Map.fromList xts₀))
    decode (TList [ TInt 9, t₁, TString x ]) = do
        t₀ <- decode t₁

        return (Field t₀ x)
    decode (TList (TInt 10 : t₁ : xs₁)) = do
        t₀ <- decode t₁

        let expectString (TString x) = return x
            expectString  _          = empty

        let decodeLeft = do
                strings <- traverse expectString xs₁

                return (Left (Dhall.Set.fromList strings))

        let decodeRight =
                case xs₁ of
                    [ TList [ _T₁ ] ] -> do
                        _T₀ <- decode _T₁

                        return (Right _T₀)
                    _ -> do
                        empty

        xs₀ <- decodeLeft <|> decodeRight

        return (Project t₀ xs₀)
    decode (TList [ TInt 11, TMap xTs₁ ]) = do
        let process (TString x, _T₁) = do
                mT₀ <- case _T₁ of
                    TNull -> return Nothing
                    _     -> fmap Just (decode _T₁)

                return (x, mT₀)
            process _ =
                empty

        xTs₀ <- traverse process xTs₁

        return (Union (Dhall.Map.fromList xTs₀))
    decode (TBool b) = do
        return (BoolLit b)
    decode (TList [ TInt 14, t₁, l₁, r₁ ]) = do
        t₀ <- decode t₁
        l₀ <- decode l₁
        r₀ <- decode r₁

        return (BoolIf t₀ l₀ r₀)
    decode (TList [ TInt 15, TInt n ]) = do
        Monad.guard (0 <= n)
        return (NaturalLit (fromIntegral n))
    decode (TList [ TInt 15, TInteger n ]) = do
        return (NaturalLit (fromInteger n))
    decode (TList [ TInt 16, TInt n ]) = do
        return (IntegerLit (fromIntegral n))
    decode (TList [ TInt 16, TInteger n ]) = do
        return (IntegerLit n)
    decode (THalf n) = do
        return (DoubleLit (float2Double n))
    decode (TFloat n) = do
        return (DoubleLit (float2Double n))
    decode (TDouble n) = do
        return (DoubleLit n)
    decode (TList (TInt 18 : xs)) = do
        let process (TString x : y₁ : zs) = do
                y₀ <- decode y₁

                ~(xys, z) <- process zs

                return ((x, y₀) : xys, z)
            process [ TString z ] = do
                return ([], z)
            process _ = do
                empty

        (xys, z) <- process xs

        return (TextLit (Chunks xys z))
    decode (TList [ TInt 19, t₁ ]) = do
        t₀ <- decode t₁

        return (Assert t₀)
    decode e@(TList (TInt 24 : _)) = fmap Embed (decode e)
    decode (TList (TInt 25 : xs)) = do
        let process (TString x : _A₁ : a₁ : ls₁) = do
                mA₀ <- case _A₁ of
                    TNull -> return Nothing
                    _     -> fmap Just (decode _A₁)

                a₀  <- decode a₁

                b₀ <- case ls₁ of
                    [ b₁ ] -> decode b₁
                    _      -> process ls₁

                return (Let x mA₀ a₀ b₀)
            process _ = do
                empty

        process xs
    decode (TList [ TInt 26, t₁, _T₁ ]) = do
        t₀  <- decode t₁
        _T₀ <- decode _T₁
        return (Annot t₀ _T₀)
    decode (TList [ TInt 27, t₁ ]) = do
        t₀ <- decode t₁
        return (ToMap t₀ Nothing)
    decode (TList [ TInt 27, t₁, _T₁ ]) = do
        t₀ <- decode t₁
        _T₀ <- decode _T₁
        return (ToMap t₀ (Just _T₀))
    decode (TList [ TInt 28, _T₁ ]) = do
        _T₀ <- decode _T₁
        return (ListLit (Just _T₀) empty)
    decode _ =
        empty

instance FromTerm Import where
    decode (TList (TInt 24 : h : TInt mode : TInt n : xs)) = do
        hash <- case h of
            TNull -> do
                return Nothing

            TBytes bytes -> do
                let (prefix, suffix) = Data.ByteString.splitAt 2 bytes

                case prefix of
                    "\x12\x20" -> return ()
                    _          -> empty

                digest <- case Crypto.Hash.digestFromByteString suffix of
                    Nothing     -> empty
                    Just digest -> return digest

                return (Just digest)

            _ -> do
                empty

        importMode <- case mode of
            0 -> return Code
            1 -> return RawText
            2 -> return Location
            _ -> empty

        let remote scheme = do
                let process [ TString file, q ] = do
                        query <- case q of
                            TNull     -> return Nothing
                            TString x -> return (Just x)
                            _         -> empty
                        return ([], file, query)
                    process (TString path : ys) = do
                        (paths, file, query) <- process ys
                        return (path : paths, file, query)
                    process _ = do
                        empty

                (headers, authority, paths, file, query) <- case xs of
                    headers₀ : TString authority : ys -> do
                        headers₁ <- case headers₀ of
                            TNull -> do
                                return Nothing
                            _     -> do
                                headers <- decode headers₀

                                return (Just headers)
                        (paths, file, query) <- process ys
                        return (headers₁, authority, paths, file, query)
                    _ -> do
                        empty

                let components = reverse paths
                let directory  = Directory {..}
                let path       = File {..}

                return (Remote (URL {..}))

        let local prefix = do
                let process [ TString file ] = do
                        return ([], file)
                    process (TString path : ys) = do
                        (paths, file) <- process ys
                        return (path : paths, file)
                    process _ =
                        empty

                (paths, file) <- process xs

                let components = reverse paths
                let directory  = Directory {..}

                return (Local prefix (File {..}))

        let env = do
                case xs of
                    [ TString x ] -> return (Env x)
                    _             -> empty

        let missing = return Missing

        importType <- case n of
            0 -> remote HTTP
            1 -> remote HTTPS
            2 -> local Absolute
            3 -> local Here
            4 -> local Parent
            5 -> local Home
            6 -> env
            7 -> missing
            _ -> empty

        let importHashed = ImportHashed {..}

        return (Import {..})

    decode _ = empty

instance FromTerm Void where
    decode _ = empty

strip55799Tag :: Term -> Term
strip55799Tag term =
    case term of
        TInt a ->
            TInt a
        TInteger a ->
            TInteger a
        TBytes a ->
            TBytes a
        TBytesI a ->
            TBytesI a
        TString a ->
            TString a
        TStringI a ->
            TStringI a
        TList as ->
            TList (fmap strip55799Tag as)
        TListI as ->
            TListI (fmap strip55799Tag as)
        TMap as ->
            TMap (fmap adapt as)
          where
            adapt (a, b) = (strip55799Tag a, strip55799Tag b)
        TMapI as ->
            TMapI (fmap adapt as)
          where
            adapt (a, b) = (strip55799Tag a, strip55799Tag b)
        TTagged 55799 b ->
            strip55799Tag b
        TTagged a b->
            TTagged a (strip55799Tag b)
        TBool a ->
            TBool a
        TNull ->
            TNull
        TSimple a ->
            TSimple a
        THalf a ->
            THalf a
        TFloat a ->
            TFloat a
        TDouble a ->
            TDouble a

-- | Encode a Dhall expression as a CBOR `Term`
--
-- This 'Dhall.Core.denote's the expression before encoding it. To encode an
-- already denoted expression, it is more efficient to directly use 'encode'.
encodeExpression :: Expr s Import -> Term
encodeExpression e = encode (Dhall.Core.denote e :: Expr Void Import)

-- | Decode a Dhall expression from a CBOR `Term`
decodeExpression :: FromTerm a => Term -> Either DecodingFailure (Expr s a)
decodeExpression term =
    case decodeWithoutVersion <|> decodeWithVersion of
        Just expression -> Right expression
        Nothing         -> Left (CBORIsNotDhall term)
  where
    strippedTerm = strip55799Tag term
    -- This is the behavior specified by the standard
    decodeWithoutVersion = decode strippedTerm

    -- For backwards compatibility with older expressions that have a version
    -- tag to ease the migration
    decodeWithVersion = do
        TList [ TString version, taggedTerm ] <- return strippedTerm

        -- "_" has never been a valid version string, and this ensures that we
        -- don't interpret `[ "_", 0 ]` as the expression `_` (encoded as `0`)
        -- tagged with a version string of `"_"`
        Monad.guard (version /= "_")

        decode taggedTerm

data DecodingFailure = CBORIsNotDhall Term
    deriving (Eq)

instance Exception DecodingFailure

_ERROR :: String
_ERROR = "\ESC[1;31mError\ESC[0m"

instance Show DecodingFailure where
    show (CBORIsNotDhall term) =
            _ERROR <> ": Cannot decode CBOR to Dhall\n"
        <>  "\n"
        <>  "The following CBOR expression does not encode a valid Dhall expression\n"
        <>  "\n"
        <>  "↳ " <> show term <> "\n"
