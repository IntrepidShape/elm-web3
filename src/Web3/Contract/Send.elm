module Web3.Contract.Send exposing
    ( WriteCall
    , writeCall
    , payableCall
    , withGasLimit
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
@docs writeCall, payableCall, withGasLimit
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
        , value : Maybe BigInt
        , gasLimit : Maybe Int
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
        , value = Nothing
        , gasLimit = Nothing
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
        , value = Just opts.value
        , gasLimit = Nothing
        }


{-| Set a gas limit.
-}
withGasLimit : Int -> WriteCall -> WriteCall
withGasLimit gas (WriteCall call) =
    WriteCall { call | gasLimit = Just gas }


{-| Encode a write call as an estimateGas command for the JS port.

    estimateGas myWriteCall
    -- sends { tag: "estimateGas", contract: ..., method: ..., args: ..., value: ... }
    -- JS responds with { tag: "gasEstimate", gas: "21000" }

-}
estimateGas : WriteCall -> E.Value
estimateGas (WriteCall call) =
    E.object
        ([ ( "tag", E.string "estimateGas" )
         , ( "contract", E.string (T.addressToString call.contract) )
         , ( "method", E.string call.method )
         , ( "args", E.list identity call.args )
         ]
            ++ (case call.value of
                    Just v ->
                        [ ( "value", E.string (BigInt.toString v) ) ]

                    Nothing ->
                        []
               )
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
         , ( "method", E.string call.method )
         , ( "args", E.list identity call.args )
         ]
            ++ (case call.value of
                    Just v ->
                        [ ( "value", E.string (BigInt.toString v) ) ]

                    Nothing ->
                        []
               )
            ++ (case call.gasLimit of
                    Just g ->
                        [ ( "gasLimit", E.int g ) ]

                    Nothing ->
                        []
               )
        )
