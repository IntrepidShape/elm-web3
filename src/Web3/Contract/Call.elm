module Web3.Contract.Call exposing
    ( ReadCall
    , readCall
    , withBlock
    , encode
    , responseDecoder
    )

{-| Type-safe contract read calls (eth\_call).

Build a read call, encode it for the JS port, decode the response.
The code generator creates typed wrappers around these primitives.

    -- Generated code uses this under the hood:
    balanceOf : Address -> ReadCall String
    balanceOf addr =
        readCall
            { contract = tokenAddress
            , method = "balanceOf"
            , args = [ Encode.address addr ]
            , decoder = Decode.string
            }

@docs ReadCall
@docs readCall, withBlock, encode, responseDecoder

-}

import Json.Decode as D
import Json.Encode as E
import Web3.Types as T


{-| A read-only contract call with a typed return value.
-}
type ReadCall a
    = ReadCall
        { contract : T.Address
        , method : String
        , args : List E.Value
        , decoder : D.Decoder a
        , block : T.BlockNumber
        , id : String
        }


{-| Create a read call. The `id` is echoed back in the response so you can
match responses to requests when multiple calls are in flight.
-}
readCall :
    { contract : T.Address
    , method : String
    , args : List E.Value
    , decoder : D.Decoder a
    , id : String
    }
    -> ReadCall a
readCall opts =
    ReadCall
        { contract = opts.contract
        , method = opts.method
        , args = opts.args
        , decoder = opts.decoder
        , block = T.Latest
        , id = opts.id
        }


{-| Set the block number for the call.
-}
withBlock : T.BlockNumber -> ReadCall a -> ReadCall a
withBlock block (ReadCall call) =
    ReadCall { call | block = block }


{-| Encode a read call for the JS port.
-}
encode : ReadCall a -> E.Value
encode (ReadCall call) =
    E.object
        [ ( "tag", E.string "call" )
        , ( "id", E.string call.id )
        , ( "contract", E.string (T.addressToString call.contract) )
        , ( "method", E.string call.method )
        , ( "args", E.list identity call.args )
        , ( "block", encodeBlock call.block )
        ]


{-| Get the response decoder for a read call.
-}
responseDecoder : ReadCall a -> D.Decoder a
responseDecoder (ReadCall call) =
    call.decoder



-- INTERNAL


encodeBlock : T.BlockNumber -> E.Value
encodeBlock block =
    case block of
        T.BlockNum n ->
            E.int n

        T.Latest ->
            E.string "latest"

        T.Pending ->
            E.string "pending"

        T.Earliest ->
            E.string "earliest"
