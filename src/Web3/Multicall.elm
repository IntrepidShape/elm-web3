module Web3.Multicall exposing
    ( CallSpec
    , callSpec
    , MulticallRequest
    , CallResult
    , batch
    , encode
    , responseDecoder
    )

{-| Batch multiple contract reads into a single eth\_call via Multicall3.

The Multicall3 contract (0xcA11bde05977b3631167028862bE2a173976CA11) is
deployed on Ethereum, PulseChain, and most EVM networks. It lets you pack N
read calls into one RPC round-trip.

    import Web3.Multicall as Multicall
    import Web3.Abi.Encode as Encode

    let
        req =
            Multicall.batch "balance-check"
                [ Multicall.callSpec tokenAddress "balanceOf(address)" [ Encode.address myAddr ]
                , Multicall.callSpec tokenAddress "totalSupply()" []
                ]
    in
    -- Outgoing port: web3Cmd (Multicall.encode req)
    -- Incoming port: match on { tag = "multicallResult" } and apply responseDecoder

@docs CallSpec, callSpec, MulticallRequest, CallResult
@docs batch, encode, responseDecoder

-}

import Json.Decode as D
import Json.Encode as E
import Web3.Types as T


{-| A single call specification for inclusion in a multicall batch.
-}
type CallSpec
    = CallSpec
        { contract : T.Address
        , method : String
        , args : List E.Value
        }


{-| A batched multicall request with a correlation id.
-}
type MulticallRequest
    = MulticallRequest
        { id : String
        , calls : List CallSpec
        }


{-| The result of a single call within a multicall batch.

`data` is the raw ABI-encoded return value as a hex string (0x-prefixed).
Apply your specific decoder (e.g. from Web3.Abi.Decode) to parse it.

-}
type alias CallResult =
    { success : Bool
    , data : String
    }


{-| Build a CallSpec for a contract read.

    Multicall.callSpec
        pairAddress
        "getReserves()"
        []

-}
callSpec : T.Address -> String -> List E.Value -> CallSpec
callSpec contract method args =
    CallSpec { contract = contract, method = method, args = args }


{-| Batch a list of call specs into a multicall request.

The `id` is echoed back in the `multicallResult` response so you can match
responses to requests when multiple batches are in flight.

-}
batch : String -> List CallSpec -> MulticallRequest
batch id calls =
    MulticallRequest { id = id, calls = calls }


{-| Encode a multicall request for the JS port.

Produces:

    { "tag": "multicall"
    , "id": "..."
    , "calls": [ { "contract": "0x...", "method": "...", "args": [...] }, ... ]
    }

-}
encode : MulticallRequest -> E.Value
encode (MulticallRequest req) =
    E.object
        [ ( "tag", E.string "multicall" )
        , ( "id", E.string req.id )
        , ( "calls", E.list encodeCallSpec req.calls )
        ]


{-| Decoder for the `multicallResult` port response.

Expects:

    { "tag": "multicallResult"
    , "id": "..."
    , "results": [ { "success": true, "data": "0x..." }, ... ]
    }

Results are in the same order as the original call specs.

-}
responseDecoder : D.Decoder (List CallResult)
responseDecoder =
    D.field "results" (D.list callResultDecoder)



-- INTERNAL


encodeCallSpec : CallSpec -> E.Value
encodeCallSpec (CallSpec spec) =
    E.object
        [ ( "contract", E.string (T.addressToString spec.contract) )
        , ( "method", E.string spec.method )
        , ( "args", E.list identity spec.args )
        ]


callResultDecoder : D.Decoder CallResult
callResultDecoder =
    D.map2 CallResult
        (D.field "success" D.bool)
        (D.field "data" D.string)
