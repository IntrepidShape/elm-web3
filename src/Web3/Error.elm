module Web3.Error exposing
    ( Error(..)
    , classify
    , decoder
    , fromDecodeError
    , toString
    , code
    )

{-| The one error type every failure at the JS boundary decodes into.

Before this module existed the bridge collapsed every failure into a string:
EIP-1193 code `4001` became a `rejected` tag and everything else became
`failed: <message>`. `err.code` never crossed the boundary, so `4902`
(the chain is not in the wallet) was indistinguishable from a dropped
connection, and the standard `switchChain` -> `addChain` -> retry flow could
not be written at all. `-32002` ("already processing a request") was only
recoverable inside connect, and a revert was a substring match away from a
network blip.

Now the shim forwards the numeric code, the wallet message, and the raw
revert payload, and this module turns those three fields into a value you can
`case` on:

    case walletError of
        Web3.Error.ChainNotAdded ->
            -- the retry flow the old string-typed channel made impossible
            ( model, web3Cmd (Wallet.encode (Wallet.addChain pulseChain)) )

        Web3.Error.RequestPending ->
            ( { model | toast = Just "Check your wallet" }, Cmd.none )

        Web3.Error.UserRejected ->
            ( model, Cmd.none )

        other ->
            ( { model | banner = Just (Web3.Error.toString other) }, Cmd.none )

The wire shape this decodes is the failure payload the shim emits:

    { tag: "failed", error: "execution reverted", code: -32000, revertData: "0x08c3.." }

@docs Error
@docs classify, decoder, fromDecodeError, toString, code

-}

import Json.Decode as D
import Web3.Abi.Decode as AbiDecode


{-| Every way a request across the JS boundary can fail.

  - `UserRejected` -- EIP-1193 `4001`. The user dismissed the wallet prompt.
    Expected, not exceptional: do not show it as an error.
  - `RequestPending` -- EIP-1193 `-32002`. A request is already open in the
    wallet; the user has to go look at it. Retrying just queues another one.
  - `ChainNotAdded` -- EIP-1193 `4902`. The wallet does not know this chain,
    so `wallet_switchEthereumChain` cannot switch to it. Send `addChain`
    then `switchChain` again.
  - `RpcError codeNumber message` -- any other JSON-RPC or provider error,
    with the code preserved so a caller can match on codes this library has
    no opinion about.
  - `Reverted { reason, data }` -- the transaction (or simulation) reverted.
    `reason` is the decoded `Error(string)` payload when there was one;
    `data` is the raw revert bytes, which is the only thing a custom error
    can be resolved against.
  - `Panic panicCode` -- a Solidity `Panic(uint256)`: `0x11` overflow,
    `0x12` divide by zero, `0x32` index out of bounds, and so on.
  - `DecodeError message` -- the boundary produced something Elm could not
    read (a malformed address, a response that failed its decoder).
  - `NetworkError message` -- transport-level failure with no code at all.

-}
type Error
    = UserRejected
    | RequestPending
    | ChainNotAdded
    | RpcError Int String
    | Reverted { reason : Maybe String, data : Maybe String }
    | Panic Int
    | DecodeError String
    | NetworkError String


{-| EIP-1193 `4001`: the user rejected the request.
-}
userRejectedCode : Int
userRejectedCode =
    4001


{-| EIP-1193 `-32002`: a matching request is already pending.
-}
requestPendingCode : Int
requestPendingCode =
    -32002


{-| EIP-1193 `4902`: the wallet has no configuration for this chain.
-}
chainNotAddedCode : Int
chainNotAddedCode =
    4902


{-| Turn the three fields the boundary carries into an `Error`.

    classify { code = Just 4902, message = "Unrecognized chain ID", revertData = Nothing }
    --> ChainNotAdded

    classify { code = Nothing, message = "Failed to fetch", revertData = Nothing }
    --> NetworkError "Failed to fetch"

Revert data wins over a generic provider code, because a wallet reports a
revert as its own transport error (`-32000`, `-32603`) with the useful part
buried in `data`. A recognised code (`4001`, `-32002`, `4902`) still wins
over revert data -- those three are decisions the user or the wallet made,
not something the chain said.

-}
classify : { code : Maybe Int, message : String, revertData : Maybe String } -> Error
classify details =
    case details.code of
        Just c ->
            if c == userRejectedCode then
                UserRejected

            else if c == requestPendingCode then
                RequestPending

            else if c == chainNotAddedCode then
                ChainNotAdded

            else
                revertOr (RpcError c details.message) details.revertData

        Nothing ->
            revertOr (NetworkError details.message) details.revertData


revertOr : Error -> Maybe String -> Error
revertOr fallback maybeData =
    case Maybe.andThen revertError maybeData of
        Just err ->
            err

        Nothing ->
            fallback


{-| Any hex payload at least a selector long is revert data: either a
`Panic(uint256)`, or a revert whose reason may or may not decode. Anything
shorter (or not hex at all) is not revert data and the caller keeps its
own fallback.
-}
revertError : String -> Maybe Error
revertError data =
    let
        raw =
            stripHexPrefix data
    in
    if String.length raw < 8 || not (String.all isHexDigit raw) then
        Nothing

    else
        case panicCode raw of
            Just p ->
                Just (Panic p)

            Nothing ->
                Just
                    (Reverted
                        { reason = AbiDecode.decodeRevertReason data
                        , data = Just data
                        }
                    )


{-| Decode a failure message straight off the port.

Tag-aware, because the shim reports the two outcomes the user caused with
their own tags rather than as a code: `rejected` / `connectRejected` are
[`UserRejected`](#Error) and `connectPending` is
[`RequestPending`](#Error). Everything else is read out of the
`error` / `code` / `revertData` fields by [`classify`](#classify).

    D.decodeValue Web3.Error.decoder incoming

-}
decoder : D.Decoder Error
decoder =
    D.oneOf
        [ D.field "tag" D.string |> D.andThen taggedDecoder
        , payloadDecoder
        ]


taggedDecoder : String -> D.Decoder Error
taggedDecoder tag =
    case tag of
        "rejected" ->
            D.succeed UserRejected

        "connectRejected" ->
            D.succeed UserRejected

        "connectPending" ->
            D.succeed RequestPending

        _ ->
            payloadDecoder


payloadDecoder : D.Decoder Error
payloadDecoder =
    D.map3
        (\c message revertData ->
            classify { code = c, message = message, revertData = revertData }
        )
        (D.maybe (D.field "code" D.int))
        (D.oneOf
            [ D.field "error" D.string
            , D.field "message" D.string
            , D.succeed ""
            ]
        )
        (D.maybe (D.field "revertData" D.string))


{-| Lift a JSON decoding failure into the same channel as everything else,
so an application has one error type rather than two.

    case D.decodeValue (Call.responseDecoder totalSupply) value of
        Ok supply ->
            ...

        Err jsonErr ->
            handle (Web3.Error.fromDecodeError jsonErr)

-}
fromDecodeError : D.Error -> Error
fromDecodeError err =
    DecodeError (D.errorToString err)


{-| The EIP-1193 / JSON-RPC code behind an error, when there was one.
`Nothing` for the failures that never had a code: a revert, a panic, a
decode failure, a transport error.
-}
code : Error -> Maybe Int
code err =
    case err of
        UserRejected ->
            Just userRejectedCode

        RequestPending ->
            Just requestPendingCode

        ChainNotAdded ->
            Just chainNotAddedCode

        RpcError c _ ->
            Just c

        Reverted _ ->
            Nothing

        Panic _ ->
            Nothing

        DecodeError _ ->
            Nothing

        NetworkError _ ->
            Nothing


{-| A one-line rendering, for a banner or a log. Not for control flow --
that is what the constructors are for.
-}
toString : Error -> String
toString err =
    case err of
        UserRejected ->
            "request rejected in the wallet"

        RequestPending ->
            "a wallet request is already open -- check your wallet"

        ChainNotAdded ->
            "this chain is not configured in the wallet"

        RpcError c message ->
            "RPC error " ++ String.fromInt c ++ ": " ++ message

        Reverted details ->
            case details.reason of
                Just reason ->
                    "reverted: " ++ reason

                Nothing ->
                    case details.data of
                        Just raw ->
                            "reverted (" ++ String.left 10 raw ++ ")"

                        Nothing ->
                            "reverted"

        Panic p ->
            "panic 0x" ++ toHex p

        DecodeError message ->
            "could not decode the response: " ++ message

        NetworkError message ->
            "network error: " ++ message



-- INTERNAL


stripHexPrefix : String -> String
stripHexPrefix s =
    if String.startsWith "0x" s || String.startsWith "0X" s then
        String.dropLeft 2 s

    else
        s


isHexDigit : Char -> Bool
isHexDigit c =
    Char.isDigit c || (Char.toLower c >= 'a' && Char.toLower c <= 'f')


{-| `Panic(uint256)` is selector `4e487b71` followed by one word holding the
panic code.
-}
panicCode : String -> Maybe Int
panicCode raw =
    if String.toLower (String.left 8 raw) == "4e487b71" && String.length raw >= 72 then
        hexToInt (String.left 64 (String.dropLeft 8 raw))

    else
        Nothing


{-| Read one 32-byte word as an Int. Anything that does not fit in the safe
integer range is rejected rather than truncated: a panic code is a small
number, and a word that is not one is not a panic code.
-}
hexToInt : String -> Maybe Int
hexToInt hex =
    let
        keep =
            12

        leading =
            String.dropRight keep hex

        tail =
            String.right keep hex
    in
    if String.any (\c -> c /= '0') leading then
        Nothing

    else
        String.foldl
            (\c acc ->
                Maybe.andThen
                    (\n -> Maybe.map (\d -> n * 16 + d) (hexDigit c))
                    acc
            )
            (Just 0)
            tail


hexDigit : Char -> Maybe Int
hexDigit c =
    let
        lower =
            Char.toLower c
    in
    if Char.isDigit c then
        Just (Char.toCode c - Char.toCode '0')

    else if lower >= 'a' && lower <= 'f' then
        Just (10 + Char.toCode lower - Char.toCode 'a')

    else
        Nothing


toHex : Int -> String
toHex n =
    if n < 0 then
        "-" ++ toHex (negate n)

    else if n < 16 then
        String.fromChar (hexChar n)

    else
        toHex (n // 16) ++ String.fromChar (hexChar (modBy 16 n))


hexChar : Int -> Char
hexChar n =
    if n < 10 then
        Char.fromCode (Char.toCode '0' + n)

    else
        Char.fromCode (Char.toCode 'a' + n - 10)
