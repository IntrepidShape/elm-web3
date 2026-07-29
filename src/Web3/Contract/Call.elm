module Web3.Contract.Call exposing
    ( ReadCall
    , readCall
    , readCallRaw
    , withBlock
    , withFrom
    , encode
    , responseDecoder
    )

{-| Type-safe contract read calls (eth\_call).

Build a read call, encode it for the JS port, decode the response.
The return type is parameterized so your decoder is checked at compile time.

    import Web3.Contract.Call as Call
    import Web3.Abi.Decode as Decode
    import Web3.Abi.Encode as Encode

    -- Read a uint256 return value
    totalSupply : T.Address -> Call.ReadCall BigInt
    totalSupply token =
        Call.readCall
            { contract = token
            , method = "totalSupply()"
            , args = []
            , decoder = Decode.uint256
            , id = "total-supply"
            }

    -- Simulate a write to catch reverts before broadcasting
    simulate : T.Address -> BigInt -> T.Address -> Call.ReadCall Bool
    simulate router amount caller =
        Call.readCall
            { contract = router
            , method = "buy(uint256)"
            , args = [ Encode.uint256 amount ]
            , decoder = Decode.bool
            , id = "sim-buy"
            }
            |> Call.withFrom caller

    -- Send via port
    web3Cmd (Call.encode (totalSupply tokenAddress))

    -- Decode response
    result = D.decodeValue (Call.responseDecoder myCall) incoming

Related modules: `Web3.Multicall` for batching multiple reads into one RPC call;
`Web3.Contract.Send` for write calls.

@docs ReadCall
@docs readCall, readCallRaw, withBlock, withFrom, encode, responseDecoder

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
        , data : Maybe String
        , decoder : D.Decoder a
        , block : T.BlockNumber
        , id : String
        , from : Maybe T.Address
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
        , data = Nothing
        , decoder = opts.decoder
        , block = T.Latest
        , id = opts.id
        , from = Nothing
        }


{-| Create a read call from **pre-built hex calldata** -- the result of
[`Web3.Abi.Calldata.calldata`](Web3-Abi-Calldata#calldata). The JS port
bridge sends `data` directly without re-encoding, so the wire path is
entirely pure-Elm: no method-name string, no arg encoding outside of Elm.

    -- balanceOf(address) -- selector baked at codegen time
    balanceOf : T.Address -> T.Address -> ReadCall BigInt
    balanceOf contract holder =
        readCallRaw
            { contract = contract
            , data = Calldata.calldata "70a08231" [ Calldata.address holder ]
            , decoder = AbiDecode.uint256
            , id = "balanceOf"
            }

The `data` argument must be a complete `"0x..."` calldata string including the
4-byte function selector.
-}
readCallRaw :
    { contract : T.Address
    , data : String
    , decoder : D.Decoder a
    , id : String
    }
    -> ReadCall a
readCallRaw opts =
    ReadCall
        { contract = opts.contract
        , method = ""
        , args = []
        , data = Just opts.data
        , decoder = opts.decoder
        , block = T.Latest
        , id = opts.id
        , from = Nothing
        }


{-| Set the block number for the call.
-}
withBlock : T.BlockNumber -> ReadCall a -> ReadCall a
withBlock block (ReadCall call) =
    ReadCall { call | block = block }


{-| Add a `from` address -- turns eth\_call into a simulation of a write.
Catches reverts without broadcasting.

    simulateBuy tokenAddress amount userAddress
        |> withFrom userAddress
        |> encode
        |> web3Cmd

-}
withFrom : T.Address -> ReadCall a -> ReadCall a
withFrom addr (ReadCall call) =
    ReadCall { call | from = Just addr }


{-| Encode a read call for the JS port.

    encode myReadCall
    -- sends { tag: "call", id: ..., contract: ..., block: ..., method: ..., args: ... }
    -- raw-calldata reads send { tag: "call", id: ..., contract: ..., data: ... }
    -- JS replies with { tag: "callResult", id: ..., data: "0x..." }, whose
    -- `data` field is what `responseDecoder` reads.

A failure replies on the shared failure channel instead --
`{ tag: "failed", error, code, revertData }` -- which
[`Web3.Error.decoder`](Web3-Error#decoder) turns into a typed
[`Web3.Error.Error`](Web3-Error#Error), so a reverted simulation is
distinguishable from a dead RPC without matching on English.

-}
encode : ReadCall a -> E.Value
encode (ReadCall call) =
    let
        base =
            [ ( "tag", E.string "call" )
            , ( "id", E.string call.id )
            , ( "contract", E.string (T.addressToString call.contract) )
            , ( "block", encodeBlock call.block )
            ]

        payload =
            case call.data of
                Just hex ->
                    [ ( "data", E.string hex ) ]

                Nothing ->
                    [ ( "method", E.string call.method )
                    , ( "args", E.list identity call.args )
                    ]

        from =
            case call.from of
                Just addr ->
                    [ ( "from", E.string (T.addressToString addr) ) ]

                Nothing ->
                    []
    in
    E.object (base ++ payload ++ from)


{-| Get the response decoder for a read call.
-}
responseDecoder : ReadCall a -> D.Decoder a
responseDecoder (ReadCall call) =
    call.decoder



-- INTERNAL


encodeBlock : T.BlockNumber -> E.Value
encodeBlock =
    T.encodeBlockNumber
