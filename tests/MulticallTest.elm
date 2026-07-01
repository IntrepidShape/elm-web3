module MulticallTest exposing (suite)

{-| Property tests for Web3.Multicall.

Two invariants matter for a batch codec, and both are pure (no JS port needed):

1.  **Encode preserves the batch.** `encode (batch id specs)` must emit a
    `"multicall"` envelope whose `id` is the given id and whose `calls` are the
    given specs in the same order, each with its contract address rendered
    exactly, its method string intact, and its args in order. Losing, dropping,
    reordering, or corrupting a call would silently send the wrong reads.

2.  **responseDecoder preserves per-call results in order.** The Multicall3
    contract returns one `(success, data)` per input call, positionally aligned
    with the request. If `responseDecoder` reordered or merged results, callers
    would decode call N's return data against call M's decoder. This is the
    "aggregation preserves per-call decode correctness" invariant.

-}

import Expect
import Fuzz exposing (Fuzzer)
import Json.Decode as D
import Json.Encode as E
import Test exposing (..)
import Web3.Multicall as Multicall exposing (CallResult)
import Web3.Types as T


suite : Test
suite =
    describe "Web3.Multicall"
        [ encodeTests
        , responseDecoderTests
        ]



-- FUZZERS


{-| A lowercase hex digit character (0-9, a-f).
-}
hexCharFuzzer : Fuzzer Char
hexCharFuzzer =
    Fuzz.intRange 0 15
        |> Fuzz.map
            (\n ->
                if n < 10 then
                    Char.fromCode (Char.toCode '0' + n)

                else
                    Char.fromCode (Char.toCode 'a' + (n - 10))
            )


{-| A valid address string: "0x" + exactly 40 lowercase hex chars.
-}
validAddressStringFuzzer : Fuzzer String
validAddressStringFuzzer =
    Fuzz.listOfLength 40 hexCharFuzzer
        |> Fuzz.map (\chars -> "0x" ++ String.fromList chars)


{-| The plain-data description of one call, used to drive the encode test.
`args` are modelled as strings (wrapped in E.string) so we can decode and
compare them structurally.
-}
type alias CallInput =
    { addr : String
    , method : String
    , args : List String
    }


callInputFuzzer : Fuzzer CallInput
callInputFuzzer =
    Fuzz.map3 CallInput
        validAddressStringFuzzer
        Fuzz.string
        (Fuzz.list Fuzz.string)



-- ENCODE


{-| Decoder mirroring what `Multicall.encode` produces, so we can read the
envelope back and assert nothing was lost.
-}
type alias DecodedCall =
    { contract : String
    , method : String
    , args : List String
    }


envelopeDecoder : D.Decoder { tag : String, id : String, calls : List DecodedCall }
envelopeDecoder =
    D.map3 (\tag id calls -> { tag = tag, id = id, calls = calls })
        (D.field "tag" D.string)
        (D.field "id" D.string)
        (D.field "calls" (D.list decodedCallDecoder))


decodedCallDecoder : D.Decoder DecodedCall
decodedCallDecoder =
    D.map3 DecodedCall
        (D.field "contract" D.string)
        (D.field "method" D.string)
        (D.field "args" (D.list D.string))


encodeTests : Test
encodeTests =
    describe "encode"
        [ fuzz2 Fuzz.string (Fuzz.list callInputFuzzer) "envelope preserves id and every call in order" <|
            \id inputs ->
                let
                    -- Pair each input with its parsed Address, dropping any that
                    -- fail to parse (none should, given the valid fuzzer). Both
                    -- the specs and the expectations derive from this one list,
                    -- so they stay aligned regardless.
                    parsed =
                        List.filterMap
                            (\c -> Maybe.map (\a -> ( c, a )) (T.address c.addr))
                            inputs

                    specs =
                        List.map
                            (\( c, a ) -> Multicall.callSpec a c.method (List.map E.string c.args))
                            parsed

                    expectedCalls =
                        List.map
                            (\( c, a ) -> DecodedCall (T.addressToString a) c.method c.args)
                            parsed
                in
                Multicall.batch id specs
                    |> Multicall.encode
                    |> D.decodeValue envelopeDecoder
                    |> Expect.equal
                        (Ok { tag = "multicall", id = id, calls = expectedCalls })
        ]



-- RESPONSE DECODER


resultFuzzer : Fuzzer CallResult
resultFuzzer =
    Fuzz.map2 CallResult Fuzz.bool Fuzz.string


{-| Build the JSON the JS port would send for a given list of results, matching
the shape `responseDecoder` expects: `{ results: [ { success, data }, ... ] }`.
-}
encodeResults : List CallResult -> E.Value
encodeResults results =
    E.object
        [ ( "tag", E.string "multicallResult" )
        , ( "id", E.string "correlation-id" )
        , ( "results"
          , E.list
                (\r ->
                    E.object
                        [ ( "success", E.bool r.success )
                        , ( "data", E.string r.data )
                        ]
                )
                results
          )
        ]


responseDecoderTests : Test
responseDecoderTests =
    describe "responseDecoder"
        [ fuzz (Fuzz.list resultFuzzer) "decodes every result, in order, success+data intact" <|
            \results ->
                encodeResults results
                    |> D.decodeValue Multicall.responseDecoder
                    |> Expect.equal (Ok results)
        , fuzz (Fuzz.list resultFuzzer) "result count is preserved" <|
            \results ->
                encodeResults results
                    |> D.decodeValue Multicall.responseDecoder
                    |> Result.map List.length
                    |> Expect.equal (Ok (List.length results))
        ]
