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
    )

{-| Core types for EVM interaction.

All types are opaque — you can't accidentally pass a TxHash where an Address
is expected. Construction validates format.

@docs Address, TxHash, BlockNumber, ChainId, Wei, HexString
@docs address, addressToString
@docs txHash, txHashToString
@docs chainId, chainIdToInt
@docs hexString, hexStringToString

-}

import Web3.BigInt exposing (BigInt)


{-| A validated Ethereum address (0x + 40 hex chars).
-}
type Address
    = Address String


{-| A transaction hash (0x + 64 hex chars).
-}
type TxHash
    = TxHash String


{-| A block number — specific or a tag.
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


{-| Wei amount as a string (uint256 — too large for Int).
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
