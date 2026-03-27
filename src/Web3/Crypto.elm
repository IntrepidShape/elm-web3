module Web3.Crypto exposing (Cmd, Msg(..), keccak256, encode, decoder)

{-| Cryptographic utilities via the Web3 port.

@docs Cmd, Msg, keccak256, encode, decoder
-}

import Json.Decode as D
import Json.Encode as E


{-| Commands for the Crypto port. -}
type Cmd
    = RequestKeccak256 String String


{-| Messages from the Crypto port. -}
type Msg
    = GotKeccak256 String String


{-| Request the keccak256 hash of a UTF-8 string. The second argument is a request ID. -}
keccak256 : String -> String -> Cmd
keccak256 message id =
    RequestKeccak256 message id


{-| Encode a Crypto command to send through the port. -}
encode : Cmd -> E.Value
encode cmd =
    case cmd of
        RequestKeccak256 message id ->
            E.object
                [ ( "tag", E.string "keccak256" )
                , ( "message", E.string message )
                , ( "id", E.string id )
                ]


{-| Decode a Crypto message received from the port. -}
decoder : D.Decoder Msg
decoder =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "keccak256Result" ->
                        D.map2 GotKeccak256
                            (D.field "id" D.string)
                            (D.field "hash" D.string)

                    _ ->
                        D.fail ("Unknown crypto tag: " ++ tag)
            )
