module Web3.Abi.Encode exposing
    ( address
    , uint256
    , int256
    , bool
    , string
    , bytes
    , bytes32
    )

{-| Helpers to encode contract call parameters to JSON values
for passing through ports to the JS Web3 layer.

@docs address, uint256, int256, bool, string, bytes, bytes32

-}

import Web3.BigInt as BigInt exposing (BigInt)
import Json.Encode as E
import Web3.Types as T


{-| Encode an Address argument.
-}
address : T.Address -> E.Value
address addr =
    E.string (T.addressToString addr)


{-| Encode a uint256 argument from a BigInt.
-}
uint256 : BigInt -> E.Value
uint256 val =
    E.string (BigInt.toString val)


{-| Encode an int256 argument from a BigInt.
-}
int256 : BigInt -> E.Value
int256 val =
    E.string (BigInt.toString val)


{-| Encode a bool argument.
-}
bool : Bool -> E.Value
bool val =
    E.bool val


{-| Encode a string argument.
-}
string : String -> E.Value
string val =
    E.string val


{-| Encode raw bytes as a hex string.
-}
bytes : String -> E.Value
bytes val =
    E.string val


{-| Encode a bytes32 value.
-}
bytes32 : String -> E.Value
bytes32 val =
    E.string val
