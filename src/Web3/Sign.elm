module Web3.Sign exposing
    ( TypedData
    , Domain
    , TypeField
    , typedData
    , encode
    , personalSign
    , signatureDecoder
    , SignState(..)
    , SignMsg(..)
    , signUpdate
    , isSignTerminal
    , startSign
    , verify
    , recoveredDecoder
    )

{-| EIP-712 typed data signing and EIP-191 personal signing.

Build a typed data request, encode it for the JS port, decode the signature response.
Use the `SignState` machine to track the lifecycle of a single sign request.

    import Dict
    import Json.Encode as E
    import Web3.Sign as Sign

    permitRequest : T.Address -> T.Address -> BigInt -> Int -> Sign.TypedData
    permitRequest owner spender value nonce =
        Sign.typedData
            { domain =
                { name = Just "MyToken", version = Just "1"
                , chainId = Just 369, verifyingContract = Just tokenAddress
                , salt = Nothing
                }
            , types =
                Dict.fromList
                    [ ( "Permit"
                      , [ { name = "owner",    typeName = "address" }
                        , { name = "spender",  typeName = "address" }
                        , { name = "value",    typeName = "uint256" }
                        , { name = "nonce",    typeName = "uint256" }
                        , { name = "deadline", typeName = "uint256" }
                        ]
                      )
                    ]
            , primaryType = "Permit"
            , message = E.object [ ... ]
            }

    -- Send via port:
    web3Cmd (Sign.encode "permit-1" signerAddress (permitRequest owner spender value nonce))

    -- Receive via port (use signatureDecoder for the raw sig string):
    case D.decodeValue Sign.signatureDecoder incoming of
        Ok sig -> -- sig is the 0x-prefixed signature
        Err _ -> -- not a sign response

**Sign state machine** — tracks one in-flight request:

    type SignState
        = SignIdle
        | SignPending String          -- id
        | Signed String String        -- id, signature
        | SignFailed String String    -- id, error
        | SignRejected String         -- id

    -- Usage:
    ( { model | signState = Sign.startSign "permit-1" model.signState }
    , web3Cmd (Sign.encode "permit-1" addr request)
    )

    -- On port response:
    newSignState = Sign.signUpdate signMsg model.signState

@docs TypedData, Domain, TypeField
@docs typedData, encode, personalSign, signatureDecoder
@docs SignState, SignMsg
@docs startSign, signUpdate, isSignTerminal
@docs verify, recoveredDecoder

-}

import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import Web3.Types as T


{-| A single field in a struct type definition.
-}
type alias TypeField =
    { name : String
    , typeName : String
    }


{-| EIP-712 domain separator parameters. All fields are optional;
include only those your contract's domain hash covers.
-}
type alias Domain =
    { name : Maybe String
    , version : Maybe String
    , chainId : Maybe Int
    , verifyingContract : Maybe T.Address
    , salt : Maybe String
    }


{-| An EIP-712 typed data signing request.
-}
type TypedData
    = TypedData
        { domain : Domain
        , types : Dict String (List TypeField)
        , primaryType : String
        , message : E.Value
        }


{-| Construct a TypedData value.
-}
typedData :
    { domain : Domain
    , types : Dict String (List TypeField)
    , primaryType : String
    , message : E.Value
    }
    -> TypedData
typedData opts =
    TypedData opts


{-| Encode a TypedData request as a port command.

    web3Cmd (Sign.encode "my-id" signerAddress request)

The `id` is echoed back in the `signed` response so you can match
responses to requests when multiple signing requests are in flight.

-}
encode : String -> T.Address -> TypedData -> E.Value
encode id from (TypedData td) =
    E.object
        [ ( "tag", E.string "signTypedData" )
        , ( "id", E.string id )
        , ( "from", E.string (T.addressToString from) )
        , ( "data", encodeTypedData td )
        ]


{-| Sign an arbitrary message with `personal_sign` (EIP-191).

Used for login flows and simple off-chain authentication. The wallet
will display the raw message to the user before signing.

    web3Cmd (Sign.personalSign "login-1" signerAddress "Sign in to MyDapp")

Responses arrive on the same `signed` tag as EIP-712 — use `signatureDecoder`.

-}
personalSign : String -> T.Address -> String -> E.Value
personalSign id from message =
    E.object
        [ ( "tag", E.string "personalSign" )
        , ( "id", E.string id )
        , ( "from", E.string (T.addressToString from) )
        , ( "message", E.string message )
        ]


{-| Signing state machine. Tracks the lifecycle of a single sign request.

  - `SignIdle` — no sign request in progress
  - `SignPending id` — awaiting user approval for request `id`
  - `Signed id sig` — user approved; `sig` is the 0x-prefixed signature
  - `SignFailed id err` — signing failed (wallet error, network error)
  - `SignRejected id` — user explicitly cancelled in wallet UI

-}
type SignState
    = SignIdle
    | SignPending String
    | Signed String String
    | SignFailed String String
    | SignRejected String


{-| Messages from the JS sign port.
-}
type SignMsg
    = SignResponse String String
      -- ^ id, signature (tag:'signed')
    | SignError String String
      -- ^ id, error message (tag:'failed' from sign context)
    | SignCancel String
      -- ^ id (tag:'rejected' from sign context)


{-| True if the sign state is terminal (no more updates expected).
-}
isSignTerminal : SignState -> Bool
isSignTerminal state =
    case state of
        Signed _ _ ->
            True

        SignFailed _ _ ->
            True

        SignRejected _ ->
            True

        _ ->
            False


{-| Transition from `SignIdle` to `SignPending` for the given correlation id.
All other states are unchanged (a sign already in flight is not replaced).
-}
startSign : String -> SignState -> SignState
startSign id state =
    case state of
        SignIdle ->
            SignPending id

        _ ->
            state


{-| Update sign state from a port message.
Terminal states never transition out.
-}
signUpdate : SignMsg -> SignState -> SignState
signUpdate msg state =
    if isSignTerminal state then
        state

    else
        case msg of
            SignResponse id sig ->
                case state of
                    SignPending pendingId ->
                        if pendingId == id then
                            Signed id sig

                        else
                            state

                    _ ->
                        state

            SignError id err ->
                case state of
                    SignPending pendingId ->
                        if pendingId == id then
                            SignFailed id err

                        else
                            state

                    _ ->
                        state

            SignCancel id ->
                case state of
                    SignPending pendingId ->
                        if pendingId == id then
                            SignRejected id

                        else
                            state

                    _ ->
                        state


{-| Decode the `signed` response from the JS port.

    case D.decodeValue Sign.signatureDecoder incoming of
        Ok sig ->
            -- sig : String — the 0x-prefixed signature
        Err _ ->
            -- handle decode error

-}
signatureDecoder : D.Decoder String
signatureDecoder =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "signed" ->
                        D.field "signature" D.string

                    _ ->
                        D.fail ("Expected 'signed' tag, got: " ++ tag)
            )


{-| Verify an EIP-191 `personal_sign` signature by recovering the signer
address (`personal_ecRecover`).

    web3Cmd
        (Sign.verify
            { id = "login-verify-1"
            , message = "Sign in to MyDapp"
            , signature = sig
            }
        )

The recovered address arrives on the `recovered` tag — decode it with
[`recoveredDecoder`](#recoveredDecoder) and compare it against the address
that claims to have signed. Failures arrive on the standard `failed` tag.

This is a standalone encoder returning the port value directly (like
[`personalSign`](#personalSign)) rather than a new `Cmd`/`Msg` variant —
extending an exposed custom type is a MAJOR change under Elm's enforced
semver, so additive functions keep this MINOR-safe.

-}
verify : { id : String, message : String, signature : String } -> E.Value
verify { id, message, signature } =
    E.object
        [ ( "tag", E.string "ecRecover" )
        , ( "id", E.string id )
        , ( "message", E.string message )
        , ( "signature", E.string signature )
        ]


{-| Decode the `recovered` response from a [`verify`](#verify) request.

    case D.decodeValue Sign.recoveredDecoder incoming of
        Ok { id, address } ->
            -- address : String — the 0x-prefixed recovered signer
        Err _ ->
            -- not a recovered response

Standalone (not a `SignMsg` variant) for the same additive-safety reason
as [`verify`](#verify).

-}
recoveredDecoder : D.Decoder { id : String, address : String }
recoveredDecoder =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "recovered" ->
                        D.map2 (\id address -> { id = id, address = address })
                            (D.field "id" D.string)
                            (D.field "address" D.string)

                    _ ->
                        D.fail ("Expected 'recovered' tag, got: " ++ tag)
            )



-- INTERNAL


encodeTypedData :
    { domain : Domain
    , types : Dict String (List TypeField)
    , primaryType : String
    , message : E.Value
    }
    -> E.Value
encodeTypedData td =
    E.object
        [ ( "domain", encodeDomain td.domain )
        , ( "types", encodeTypes td.domain td.types )
        , ( "primaryType", E.string td.primaryType )
        , ( "message", td.message )
        ]


encodeDomain : Domain -> E.Value
encodeDomain domain =
    let
        fields =
            List.filterMap identity
                [ Maybe.map (\n -> ( "name", E.string n )) domain.name
                , Maybe.map (\v -> ( "version", E.string v )) domain.version
                , Maybe.map (\c -> ( "chainId", E.int c )) domain.chainId
                , Maybe.map (\a -> ( "verifyingContract", E.string (T.addressToString a) )) domain.verifyingContract
                , Maybe.map (\s -> ( "salt", E.string s )) domain.salt
                ]
    in
    E.object fields


encodeTypes : Domain -> Dict String (List TypeField) -> E.Value
encodeTypes domain userTypes =
    let
        domainFields =
            List.filterMap identity
                [ Maybe.map (\_ -> { name = "name", typeName = "string" }) domain.name
                , Maybe.map (\_ -> { name = "version", typeName = "string" }) domain.version
                , Maybe.map (\_ -> { name = "chainId", typeName = "uint256" }) domain.chainId
                , Maybe.map (\_ -> { name = "verifyingContract", typeName = "address" }) domain.verifyingContract
                , Maybe.map (\_ -> { name = "salt", typeName = "bytes32" }) domain.salt
                ]

        allTypes =
            Dict.insert "EIP712Domain" domainFields userTypes
    in
    E.dict identity (E.list encodeTypeField) allTypes


encodeTypeField : TypeField -> E.Value
encodeTypeField field =
    E.object
        [ ( "name", E.string field.name )
        , ( "type", E.string field.typeName )
        ]
