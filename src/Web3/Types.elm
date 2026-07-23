module Web3.Types exposing
    ( Address
    , TxHash
    , BlockNumber(..)
    , ChainId
    , Wei
    , HexString
    , address
    , addressToString
    , txHash
    , txHashToString
    , chainId
    , chainIdToInt
    , hexString
    , hexStringToString
    , encodeBlockNumber
    )

{-| Core opaque types for EVM interaction.

All types are opaque -- you can't accidentally pass a `TxHash` where an `Address`
is expected. Construction validates format and returns `Maybe` so invalid input
is a compile-time-visible code path, not a runtime crash.

    import Web3.Types as T

    -- Validate on input boundary (e.g. from a URL param or user field):
    case T.address rawString of
        Just addr ->
            -- addr : T.Address -- safe to use everywhere
        Nothing ->
            -- show validation error

    -- BlockNumber is used by Contract.Call, Block, Fee, and Query:
    T.encodeBlockNumber T.Latest    == Json.Encode.string "latest"
    T.encodeBlockNumber (T.BlockNum 1000) == Json.Encode.int 1000

`Wei` is an alias for `Web3.BigInt.BigInt` -- use `Web3.Units.formatEther` to
convert to a human-readable string.

@docs Address, TxHash, BlockNumber, ChainId, Wei, HexString
@docs address, addressToString
@docs txHash, txHashToString
@docs chainId, chainIdToInt
@docs hexString, hexStringToString
@docs encodeBlockNumber

-}

import Json.Encode as E
import Web3.BigInt exposing (BigInt)


{-| A validated Ethereum address (0x + 40 hex chars).
-}
type Address
    = Address String


{-| A transaction hash (0x + 64 hex chars).
-}
type TxHash
    = TxHash String


{-| A block number -- specific or a tag.
-}
type BlockNumber
    = BlockNum Int
    | Latest
    | Pending
    | Earliest


{-| An EVM chain ID.
-}
type ChainId
    = ChainId Int


{-| A raw hex string.
-}
type HexString
    = HexString String


{-| Wei amount as a string (uint256 -- too large for Int).
-}
type alias Wei =
    BigInt



-- CONSTRUCTORS


{-| Create an Address from a hex string. Returns Nothing if invalid.
-}
address : String -> Maybe Address
address str =
    let
        lower =
            String.toLower str
    in
    if String.startsWith "0x" lower && String.length lower == 42 && isHex (String.dropLeft 2 lower) then
        Just (Address lower)

    else
        Nothing


{-| Create a TxHash from a hex string.
-}
txHash : String -> Maybe TxHash
txHash str =
    let
        lower =
            String.toLower str
    in
    if String.startsWith "0x" lower && String.length lower == 66 && isHex (String.dropLeft 2 lower) then
        Just (TxHash lower)

    else
        Nothing


{-| Create a ChainId.
-}
chainId : Int -> ChainId
chainId =
    ChainId


{-| Create a HexString.
-}
hexString : String -> Maybe HexString
hexString str =
    if String.startsWith "0x" str && isHex (String.dropLeft 2 str) then
        Just (HexString str)

    else
        Nothing



-- ACCESSORS


{-| Extract the string value of an Address.
-}
addressToString : Address -> String
addressToString (Address s) =
    s


{-| Extract the string value of a TxHash.
-}
txHashToString : TxHash -> String
txHashToString (TxHash s) =
    s


{-| Extract the integer value of a ChainId.
-}
chainIdToInt : ChainId -> Int
chainIdToInt (ChainId n) =
    n


{-| Extract the string value of a HexString.
-}
hexStringToString : HexString -> String
hexStringToString (HexString s) =
    s



-- INTERNAL


isHex : String -> Bool
isHex str =
    String.all isHexDigit str


isHexDigit : Char -> Bool
isHexDigit c =
    Char.isAlphaNum c
        && (let
                code =
                    Char.toCode c
            in
            (code >= Char.toCode '0' && code <= Char.toCode '9')
                || (code >= Char.toCode 'a' && code <= Char.toCode 'f')
                || (code >= Char.toCode 'A' && code <= Char.toCode 'F')
           )


{-| Encode a BlockNumber for JSON-RPC (e.g. for eth_call block parameter).
-}
encodeBlockNumber : BlockNumber -> E.Value
encodeBlockNumber bn =
    case bn of
        BlockNum n ->
            E.int n

        Latest ->
            E.string "latest"

        Pending ->
            E.string "pending"

        Earliest ->
            E.string "earliest"
