module Web3.Contract.Send exposing
    ( WriteCall
    , writeCall
    , writeCallRaw
    , payableCall
    , payableCallRaw
    , withGasLimit
    , withFrom
    , encode
    , estimateGas
    , deployCall
    , encodeRawSend
    )

{-| Type-safe contract write calls (eth\_sendTransaction).

Build a write call, encode it for the JS port, optionally estimate gas first.

    -- Non-payable: approve
    approve : Address -> BigInt -> WriteCall
    approve spender amount =
        writeCall
            { contract = tokenAddress
            , method = "approve"
            , args = [ Encode.address spender, Encode.uint256 amount ]
            }

    -- Payable: buy
    buy : BigInt -> Wei -> WriteCall
    buy minTokens value =
        payableCall
            { contract = routerAddress
            , method = "buy"
            , args = [ Encode.uint256 minTokens ]
            , value = value
            }

@docs WriteCall
@docs writeCall, writeCallRaw, payableCall, payableCallRaw, withGasLimit, withFrom
@docs encode, estimateGas, deployCall, encodeRawSend

-}

import Json.Encode as E
import Web3.BigInt as BigInt exposing (BigInt)
import Web3.Types as T


{-| A write call to a contract.
-}
type WriteCall
    = WriteCall
        { contract : T.Address
        , method : String
        , args : List E.Value
        , data : Maybe String
        , value : Maybe BigInt
        , gasLimit : Maybe Int
        , from : Maybe T.Address
        }


{-| Create a non-payable write call.
-}
writeCall :
    { contract : T.Address
    , method : String
    , args : List E.Value
    }
    -> WriteCall
writeCall opts =
    WriteCall
        { contract = opts.contract
        , method = opts.method
        , args = opts.args
        , data = Nothing
        , value = Nothing
        , gasLimit = Nothing
        , from = Nothing
        }


{-| Create a write call from pre-built hex calldata -- the result of
[`Web3.Abi.Calldata.calldata`](Web3-Abi-Calldata#calldata). The JS port
bridge sends `data` directly without re-encoding.

    approve : T.Address -> T.Address -> BigInt -> WriteCall
    approve contract spender amount =
        writeCallRaw
            { contract = contract
            , data =
                Calldata.calldata "095ea7b3"
                    [ Calldata.address spender
                    , Calldata.uint256 amount
                    ]
            }

-}
writeCallRaw :
    { contract : T.Address
    , data : String
    }
    -> WriteCall
writeCallRaw opts =
    WriteCall
        { contract = opts.contract
        , method = ""
        , args = []
        , data = Just opts.data
        , value = Nothing
        , gasLimit = Nothing
        , from = Nothing
        }


{-| Create a payable write call with a value.
-}
payableCall :
    { contract : T.Address
    , method : String
    , args : List E.Value
    , value : BigInt
    }
    -> WriteCall
payableCall opts =
    WriteCall
        { contract = opts.contract
        , method = opts.method
        , args = opts.args
        , data = Nothing
        , value = Just opts.value
        , gasLimit = Nothing
        , from = Nothing
        }


{-| Create a payable write call from pre-built hex calldata + a value.
-}
payableCallRaw :
    { contract : T.Address
    , data : String
    , value : BigInt
    }
    -> WriteCall
payableCallRaw opts =
    WriteCall
        { contract = opts.contract
        , method = ""
        , args = []
        , data = Just opts.data
        , value = Just opts.value
        , gasLimit = Nothing
        , from = Nothing
        }


{-| Set a gas limit.
-}
withGasLimit : Int -> WriteCall -> WriteCall
withGasLimit gas (WriteCall call) =
    WriteCall { call | gasLimit = Just gas }


{-| Set the sender explicitly.

Without this the JS bridge estimates and sends from the wallet's first
account. Set it when the connected account is not the account the call
must run as -- an estimate taken from the wrong `msg.sender` is a
different transaction, and for anything permissioned it either reverts
or reports a gas figure the real send will not match.

    approve spender amount
        |> withFrom userAddress
        |> estimateGas
        |> web3Cmd

-}
withFrom : T.Address -> WriteCall -> WriteCall
withFrom addr (WriteCall call) =
    WriteCall { call | from = Just addr }


{-| Encode a write call as an estimateGas command for the JS port.

    estimateGas myWriteCall
    -- sends { tag: "estimateGas", contract: ..., method: ..., args: ..., value: ... }
    -- raw-calldata calls send { tag: "estimateGas", contract: ..., data: ... }
    -- JS responds with { tag: "gasEstimate", gas: "21000" }

Emits exactly the same calldata, value and sender fields as
[`encode`](#encode) does for the same call, so the returned figure
applies to the transaction that is about to be signed. Prior to 2.1 this
dropped `data` and `from`, which made every raw-calldata estimate an
estimate of a different transaction.

-}
estimateGas : WriteCall -> E.Value
estimateGas (WriteCall call) =
    E.object
        ([ ( "tag", E.string "estimateGas" )
         , ( "contract", E.string (T.addressToString call.contract) )
         ]
            ++ payloadFields call
            ++ valueFields call
            ++ fromFields call
        )


{-| Encode a contract deployment for submission via the port. -}
deployCall :
    { bytecode : String
    , args : List E.Value
    , gasLimit : Maybe Int
    } -> E.Value
deployCall opts =
    E.object
        ([ ( "tag", E.string "deploy" )
         , ( "bytecode", E.string opts.bytecode )
         , ( "args", E.list identity opts.args )
         ]
            ++ (case opts.gasLimit of
                    Just g -> [ ( "gasLimit", E.int g ) ]
                    Nothing -> []
               )
        )


{-| Encode a raw signed transaction for broadcast via the port. -}
encodeRawSend : String -> E.Value
encodeRawSend rawHex =
    E.object
        [ ( "tag", E.string "sendRawTransaction" )
        , ( "rawTx", E.string rawHex )
        ]


{-| Encode a write call for the JS port.
-}
encode : WriteCall -> E.Value
encode (WriteCall call) =
    E.object
        ([ ( "tag", E.string "send" )
         , ( "contract", E.string (T.addressToString call.contract) )
         ]
            ++ payloadFields call
            ++ valueFields call
            ++ gasFields call
            ++ fromFields call
        )



-- INTERNAL


{-| Calldata fields. Pre-built `data` wins over signature encoding: a raw
call carries method "" and no args, so encoding it would produce the
selector of the empty string.
-}
payloadFields :
    { r | method : String, args : List E.Value, data : Maybe String }
    -> List ( String, E.Value )
payloadFields call =
    case call.data of
        Just hex ->
            [ ( "data", E.string hex ) ]

        Nothing ->
            [ ( "method", E.string call.method )
            , ( "args", E.list identity call.args )
            ]


valueFields : { r | value : Maybe BigInt } -> List ( String, E.Value )
valueFields call =
    case call.value of
        Just v ->
            [ ( "value", E.string (BigInt.toString v) ) ]

        Nothing ->
            []


gasFields : { r | gasLimit : Maybe Int } -> List ( String, E.Value )
gasFields call =
    case call.gasLimit of
        Just g ->
            [ ( "gasLimit", E.int g ) ]

        Nothing ->
            []


fromFields : { r | from : Maybe T.Address } -> List ( String, E.Value )
fromFields call =
    case call.from of
        Just addr ->
            [ ( "from", E.string (T.addressToString addr) ) ]

        Nothing ->
            []
