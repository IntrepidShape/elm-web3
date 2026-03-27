module Web3.Contract.Send exposing
    ( WriteCall
    , writeCall
    , payableCall
    , withGasLimit
    , encode
    , estimateGas
    )

{-| Type-safe contract write calls (eth\_sendTransaction).

    -- Non-payable: approve
    approve : Address -> BigInt -> WriteCall
    approve spender amount =
        writeCall { ... }

    -- Payable: buy
    buy : BigInt -> Wei -> WriteCall
    buy minTokens value =
        payableCall { ..., value = value }

-}

import BigInt exposing (BigInt)
import Json.Encode as E
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
