module Web3.Abi.Encode exposing
    ( address
    , uint256
    , int256
    , bool
    , string
    , bytes
    , bytes32
    , bytesN
    , list
    , tuple2
    , tuple3
    )

{-| Helpers to encode contract call parameters to JSON values
for passing through ports to the JS Web3 layer.

@docs address, uint256, int256, bool, string, bytes, bytes32, bytesN
@docs list, tuple2, tuple3

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


{-| Encode a bytesN value (bytes1 through bytes31).
-}
bytesN : String -> E.Value
bytesN val =
    E.string val


{-| Encode a dynamic array argument.

    -- Transfer(address[],uint256[])
    Encode.list Encode.address recipients
    Encode.list Encode.uint256 amounts

-}
list : (a -> E.Value) -> List a -> E.Value
list encoder xs =
    E.list encoder xs


{-| Encode a 2-tuple (struct with two fields).

    -- swap(address token, uint256 amount)
    Encode.tuple2 Encode.address Encode.uint256 ( tokenAddr, amount )

-}
tuple2 : (a -> E.Value) -> (b -> E.Value) -> ( a, b ) -> E.Value
tuple2 ea eb ( a, b ) =
    E.list identity [ ea a, eb b ]


{-| Encode a 3-tuple (struct with three fields).
-}
tuple3 : (a -> E.Value) -> (b -> E.Value) -> (c -> E.Value) -> ( a, b, c ) -> E.Value
tuple3 ea eb ec ( a, b, c ) =
    E.list identity [ ea a, eb b, ec c ]
