module Web3.Sign exposing
    ( TypedData
    , Domain
    , TypeField
    , typedData
    , encode
    , signatureDecoder
    )

{-| EIP-712 typed data signing.

Build a typed data request, encode it for the JS port, decode the signature response.

    import Dict
    import Json.Encode as E
    import Web3.Sign as Sign

    permitDomain : Sign.Domain
    permitDomain =
        { name = Just "MyToken"
        , version = Just "1"
        , chainId = Just 1
        , verifyingContract = Just tokenAddress
        , salt = Nothing
        }

    permitTypes : Dict.Dict String (List Sign.TypeField)
    permitTypes =
        Dict.fromList
            [ ( "Permit"
              , [ { name = "owner", typeName = "address" }
                , { name = "spender", typeName = "address" }
                , { name = "value", typeName = "uint256" }
                , { name = "nonce", typeName = "uint256" }
                , { name = "deadline", typeName = "uint256" }
                ]
              )
            ]

    permitRequest : Sign.TypedData
    permitRequest =
        Sign.typedData
            { domain = permitDomain
            , types = permitTypes
            , primaryType = "Permit"
            , message =
                E.object
                    [ ( "owner", E.string "0x..." )
                    , ( "spender", E.string "0x..." )
                    , ( "value", E.string "1000000000000000000" )
                    , ( "nonce", E.int 0 )
                    , ( "deadline", E.int 9999999999 )
                    ]
            }

    -- Send via port:
    --   web3Cmd (Sign.encode "permit-1" signerAddress permitRequest)
    --
    -- Receive via port:
    --   D.decodeValue Sign.signatureDecoder incoming

@docs TypedData, Domain, TypeField
@docs typedData, encode, signatureDecoder

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
