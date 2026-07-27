port module Main exposing (main)

{-| hello-read -- the smallest useful elm-web3 program.

One `eth_call` against a public RPC. No wallet, no signing, no state
machine: this is the "how long until I see a real number from a real
contract" artefact.

Build:  cd examples/hello-read && elm make src/Main.elm --output=elm.js
Serve:  bunx serve .    (ES modules do not load over file://)

-}

import Browser
import Html exposing (Html, code, div, h1, p, text)
import Json.Decode as D
import Json.Encode as E
import Web3.Abi.Decode as Decode
import Web3.BigInt exposing (BigInt)
import Web3.Contract.Call as Call
import Web3.Types as T
import Web3.Units as Units


port web3Cmd : E.Value -> Cmd msg


port web3Sub : (D.Value -> msg) -> Sub msg


{-| DAI on Ethereum mainnet. `T.address` is the only way to build a `T.Address`,
so a typo here is a `Nothing`, never a call to the wrong contract.
-}
totalSupply : Maybe (Call.ReadCall BigInt)
totalSupply =
    T.address "0x6b175474e89094c44da98b954eedeac495271d0f"
        |> Maybe.map
            (\dai ->
                Call.readCall
                    { contract = dai
                    , method = "totalSupply()"
                    , args = []
                    , decoder = Decode.uint256
                    , id = "total-supply"
                    }
            )


init : () -> ( String, Cmd Msg )
init _ =
    case totalSupply of
        Just call ->
            ( "reading DAI totalSupply() ...", web3Cmd (Call.encode call) )

        Nothing ->
            ( "the address literal above is not a valid address", Cmd.none )


type Msg
    = GotResponse D.Value


update : Msg -> String -> ( String, Cmd Msg )
update (GotResponse raw) model =
    ( case ( D.decodeValue (D.field "tag" D.string) raw, totalSupply ) of
        ( Ok "callResult", Just call ) ->
            case D.decodeValue (D.field "data" (Call.responseDecoder call)) raw of
                Ok supply ->
                    Units.formatUnits 18 supply ++ " DAI"

                Err err ->
                    "could not decode the return value: " ++ D.errorToString err

        ( Ok "failed", _ ) ->
            "rpc call failed: "
                ++ (D.decodeValue (D.field "error" D.string) raw
                        |> Result.withDefault "unknown error"
                   )

        _ ->
            model
    , Cmd.none
    )


view : String -> Html Msg
view model =
    div [] [ h1 [] [ text "hello-read" ], p [] [ code [] [ text model ] ] ]


main : Program () String Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = \_ -> web3Sub GotResponse
        }
