module Web3.Balance exposing
    ( Cmd
    , Msg(..)
    , getBalance
    , encode
    , decoder
    )

{-| Typed balance query with correlation IDs.

This module provides a dedicated, typed interface for querying native ETH/PLS
balances. Multiple queries can be in flight simultaneously -- each carries a
correlation `id` that is echoed back so responses can be matched.

    -- Send via your port:
    web3Cmd (Web3.Balance.encode (Web3.Balance.getBalance address "my-id"))

    -- Receive via your port:
    case D.decodeValue Web3.Balance.decoder incoming of
        Ok (Web3.Balance.GotBalance id wei) ->
            -- id matches the one you sent; wei is the amount
        Err _ ->
            -- not a balance response

@docs Cmd, Msg
@docs getBalance, encode, decoder

-}

import Json.Decode as D
import Json.Encode as E
import Web3.BigInt as BigInt
import Web3.Types as T


{-| A pending balance request. Carry the address and a correlation id.
-}
type Cmd
    = RequestBalance T.Address String


{-| A resolved balance response. Contains the correlation id and the amount in wei.
-}
type Msg
    = GotBalance String T.Wei


{-| Build a balance query for `address`, tagged with `id`.
-}
getBalance : T.Address -> String -> Cmd
getBalance addr id =
    RequestBalance addr id


{-| Encode a `Cmd` for the JS port.

Produces `{tag:'getBalance', address, id}`.

-}
encode : Cmd -> E.Value
encode (RequestBalance addr id) =
    E.object
        [ ( "tag", E.string "getBalance" )
        , ( "address", E.string (T.addressToString addr) )
        , ( "id", E.string id )
        ]


{-| Decode a `{tag:'balance', id, wei}` response from the JS port.
-}
decoder : D.Decoder Msg
decoder =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "balance" ->
                        D.map2 GotBalance
                            (D.field "id" D.string)
                            (D.field "wei" BigInt.decoder)

                    _ ->
                        D.fail ("Expected 'balance' tag, got: " ++ tag)
            )
