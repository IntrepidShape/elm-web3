module TypesTest exposing (suite)

import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (..)
import Web3.Types as T


suite : Test
suite =
    describe "Web3.Types"
        [ addressTests
        , txHashTests
        , chainIdTests
        , hexStringTests
        , addressFuzzTests
        , txHashFuzzTests
        , chainIdFuzzTests
        , hexStringFuzzTests
        ]


addressTests : Test
addressTests =
    describe "address"
        [ test "accepts valid lowercase address" <|
            \_ ->
                T.address "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
                    |> Expect.notEqual Nothing
        , test "accepts valid uppercase address and lowercases it" <|
            \_ ->
                case T.address "0xABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD" of
                    Just a ->
                        T.addressToString a
                            |> Expect.equal "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"

                    Nothing ->
                        Expect.fail "Expected Just"
        , test "accepts mixed-case address (checksummed)" <|
            \_ ->
                T.address "0xAbCdEfAbCdEfAbCdEfAbCdEfAbCdEfAbCdEfAbCd"
                    |> Expect.notEqual Nothing
        , test "accepts zero address" <|
            \_ ->
                T.address "0x0000000000000000000000000000000000000000"
                    |> Expect.notEqual Nothing
        , test "rejects missing 0x prefix" <|
            \_ ->
                T.address "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
                    |> Expect.equal Nothing
        , test "rejects too short" <|
            \_ ->
                T.address "0xabcdef"
                    |> Expect.equal Nothing
        , test "rejects too long" <|
            \_ ->
                T.address "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdef"
                    |> Expect.equal Nothing
        , test "rejects non-hex characters" <|
            \_ ->
                T.address "0xGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG"
                    |> Expect.equal Nothing
        , test "rejects empty string" <|
            \_ ->
                T.address ""
                    |> Expect.equal Nothing
        , test "rejects only 0x" <|
            \_ ->
                T.address "0x"
                    |> Expect.equal Nothing
        , test "addressToString round-trips" <|
            \_ ->
                case T.address "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" of
                    Just a ->
                        T.addressToString a
                            |> Expect.equal "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

                    Nothing ->
                        Expect.fail "Expected Just"
        ]


txHashTests : Test
txHashTests =
    describe "txHash"
        [ test "accepts valid 64-char hex hash" <|
            \_ ->
                T.txHash "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"
                    |> Expect.notEqual Nothing
        , test "accepts all-zeros hash" <|
            \_ ->
                T.txHash "0x0000000000000000000000000000000000000000000000000000000000000000"
                    |> Expect.notEqual Nothing
        , test "accepts uppercase and lowercases it" <|
            \_ ->
                case T.txHash "0xABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD" of
                    Just h ->
                        T.txHashToString h
                            |> Expect.equal "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"

                    Nothing ->
                        Expect.fail "Expected Just"
        , test "rejects missing 0x prefix" <|
            \_ ->
                T.txHash "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"
                    |> Expect.equal Nothing
        , test "rejects 40-char hex (address length)" <|
            \_ ->
                T.txHash "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
                    |> Expect.equal Nothing
        , test "rejects too long" <|
            \_ ->
                T.txHash "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef"
                    |> Expect.equal Nothing
        , test "rejects non-hex characters" <|
            \_ ->
                T.txHash "0xzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
                    |> Expect.equal Nothing
        , test "rejects empty string" <|
            \_ ->
                T.txHash ""
                    |> Expect.equal Nothing
        , test "txHashToString round-trips" <|
            \_ ->
                let
                    raw =
                        "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
                in
                case T.txHash raw of
                    Just h ->
                        T.txHashToString h |> Expect.equal raw

                    Nothing ->
                        Expect.fail "Expected Just"
        ]


chainIdTests : Test
chainIdTests =
    describe "chainId"
        [ test "chainIdToInt round-trips" <|
            \_ ->
                T.chainId 369 |> T.chainIdToInt |> Expect.equal 369
        , test "works for Ethereum mainnet" <|
            \_ ->
                T.chainId 1 |> T.chainIdToInt |> Expect.equal 1
        , test "works for zero" <|
            \_ ->
                T.chainId 0 |> T.chainIdToInt |> Expect.equal 0
        ]


hexStringTests : Test
hexStringTests =
    describe "hexString"
        [ test "accepts 0x prefix with hex" <|
            \_ ->
                T.hexString "0xdeadbeef"
                    |> Expect.notEqual Nothing
        , test "accepts 0x alone" <|
            \_ ->
                T.hexString "0x"
                    |> Expect.notEqual Nothing
        , test "rejects missing 0x" <|
            \_ ->
                T.hexString "deadbeef"
                    |> Expect.equal Nothing
        , test "rejects non-hex after 0x" <|
            \_ ->
                T.hexString "0xGGGG"
                    |> Expect.equal Nothing
        , test "hexStringToString round-trips" <|
            \_ ->
                case T.hexString "0x1234abcd" of
                    Just h ->
                        T.hexStringToString h |> Expect.equal "0x1234abcd"

                    Nothing ->
                        Expect.fail "Expected Just"
        ]



-- FUZZ HELPERS


{-| Generate a random lowercase hex digit character (0-9, a-f).
-}
hexCharFuzzer : Fuzzer Char
hexCharFuzzer =
    Fuzz.intRange 0 15
        |> Fuzz.map intToHexChar


intToHexChar : Int -> Char
intToHexChar n =
    if n < 10 then
        Char.fromCode (Char.toCode '0' + n)

    else
        Char.fromCode (Char.toCode 'a' + (n - 10))


{-| Generate a valid address string: "0x" + exactly 40 lowercase hex chars.
-}
validAddressStringFuzzer : Fuzzer String
validAddressStringFuzzer =
    Fuzz.listOfLength 40 hexCharFuzzer
        |> Fuzz.map (\chars -> "0x" ++ String.fromList chars)


{-| Generate a valid tx hash string: "0x" + exactly 64 lowercase hex chars.
-}
validTxHashStringFuzzer : Fuzzer String
validTxHashStringFuzzer =
    Fuzz.listOfLength 64 hexCharFuzzer
        |> Fuzz.map (\chars -> "0x" ++ String.fromList chars)


{-| Generate a valid hex string: "0x" + variable-length lowercase hex chars.
-}
validHexStringFuzzer : Fuzzer String
validHexStringFuzzer =
    Fuzz.list hexCharFuzzer
        |> Fuzz.map (\chars -> "0x" ++ String.fromList chars)



-- FUZZ TESTS: ADDRESS


addressFuzzTests : Test
addressFuzzTests =
    describe "address fuzz"
        [ fuzz validAddressStringFuzzer "valid address string is always accepted" <|
            \str ->
                T.address str
                    |> Expect.notEqual Nothing
        , fuzz validAddressStringFuzzer "valid address toString round-trips exactly" <|
            \str ->
                case T.address str of
                    Just a ->
                        T.addressToString a |> Expect.equal str

                    Nothing ->
                        Expect.fail ("Expected Just for: " ++ str)
        , fuzz Fuzz.string "address result is always lowercase" <|
            \str ->
                case T.address str of
                    Just a ->
                        let
                            s =
                                T.addressToString a
                        in
                        s |> Expect.equal (String.toLower s)

                    Nothing ->
                        Expect.pass
        , fuzz Fuzz.string "address result always has length 42" <|
            \str ->
                case T.address str of
                    Just a ->
                        T.addressToString a
                            |> String.length
                            |> Expect.equal 42

                    Nothing ->
                        Expect.pass
        , fuzz Fuzz.string "address result always starts with 0x" <|
            \str ->
                case T.address str of
                    Just a ->
                        T.addressToString a
                            |> String.startsWith "0x"
                            |> Expect.equal True

                    Nothing ->
                        Expect.pass
        , fuzz Fuzz.string "address rejects strings not starting with 0x (case-insensitive)" <|
            \str ->
                if not (String.startsWith "0x" (String.toLower str)) then
                    T.address str |> Expect.equal Nothing

                else
                    Expect.pass
        , fuzz Fuzz.string "address rejects strings with length /= 42" <|
            \str ->
                if String.length str /= 42 then
                    T.address str |> Expect.equal Nothing

                else
                    Expect.pass
        ]



-- FUZZ TESTS: TXHASH


txHashFuzzTests : Test
txHashFuzzTests =
    describe "txHash fuzz"
        [ fuzz validTxHashStringFuzzer "valid txHash string is always accepted" <|
            \str ->
                T.txHash str
                    |> Expect.notEqual Nothing
        , fuzz validTxHashStringFuzzer "valid txHash toString round-trips exactly" <|
            \str ->
                case T.txHash str of
                    Just h ->
                        T.txHashToString h |> Expect.equal str

                    Nothing ->
                        Expect.fail ("Expected Just for: " ++ str)
        , fuzz Fuzz.string "txHash result is always lowercase" <|
            \str ->
                case T.txHash str of
                    Just h ->
                        let
                            s =
                                T.txHashToString h
                        in
                        s |> Expect.equal (String.toLower s)

                    Nothing ->
                        Expect.pass
        , fuzz Fuzz.string "txHash result always has length 66" <|
            \str ->
                case T.txHash str of
                    Just h ->
                        T.txHashToString h
                            |> String.length
                            |> Expect.equal 66

                    Nothing ->
                        Expect.pass
        , fuzz Fuzz.string "txHash result always starts with 0x" <|
            \str ->
                case T.txHash str of
                    Just h ->
                        T.txHashToString h
                            |> String.startsWith "0x"
                            |> Expect.equal True

                    Nothing ->
                        Expect.pass
        , fuzz Fuzz.string "txHash rejects strings not starting with 0x (case-insensitive)" <|
            \str ->
                if not (String.startsWith "0x" (String.toLower str)) then
                    T.txHash str |> Expect.equal Nothing

                else
                    Expect.pass
        , fuzz Fuzz.string "txHash rejects strings with length /= 66" <|
            \str ->
                if String.length str /= 66 then
                    T.txHash str |> Expect.equal Nothing

                else
                    Expect.pass
        , fuzz validAddressStringFuzzer "address strings (42 chars) are never valid txHashes" <|
            \str ->
                -- address is 42 chars, txHash requires 66 — they must never overlap
                T.txHash str |> Expect.equal Nothing
        ]



-- FUZZ TESTS: CHAINID


chainIdFuzzTests : Test
chainIdFuzzTests =
    describe "chainId fuzz"
        [ fuzz Fuzz.int "chainId int round-trips for any Int" <|
            \n ->
                T.chainId n
                    |> T.chainIdToInt
                    |> Expect.equal n
        , fuzz Fuzz.int "two chainIds with same int are equal via chainIdToInt" <|
            \n ->
                T.chainIdToInt (T.chainId n)
                    |> Expect.equal (T.chainIdToInt (T.chainId n))
        ]



-- FUZZ TESTS: HEXSTRING


hexStringFuzzTests : Test
hexStringFuzzTests =
    describe "hexString fuzz"
        [ fuzz validHexStringFuzzer "valid hex string is always accepted" <|
            \str ->
                T.hexString str
                    |> Expect.notEqual Nothing
        , fuzz validHexStringFuzzer "valid hex string toString round-trips exactly" <|
            \str ->
                case T.hexString str of
                    Just h ->
                        T.hexStringToString h |> Expect.equal str

                    Nothing ->
                        Expect.fail ("Expected Just for: " ++ str)
        , fuzz Fuzz.string "hexString result always starts with 0x" <|
            \str ->
                case T.hexString str of
                    Just h ->
                        T.hexStringToString h
                            |> String.startsWith "0x"
                            |> Expect.equal True

                    Nothing ->
                        Expect.pass
        , fuzz Fuzz.string "hexString rejects strings not starting with 0x" <|
            \str ->
                if not (String.startsWith "0x" str) then
                    T.hexString str |> Expect.equal Nothing

                else
                    Expect.pass
        , fuzz validHexStringFuzzer "hexString result chars after 0x are all valid hex digits" <|
            \str ->
                case T.hexString str of
                    Just h ->
                        T.hexStringToString h
                            |> String.dropLeft 2
                            |> String.all isHexDigit
                            |> Expect.equal True

                    Nothing ->
                        Expect.fail ("Expected Just for: " ++ str)
        ]


isHexDigit : Char -> Bool
isHexDigit c =
    let
        code =
            Char.toCode c
    in
    (code >= Char.toCode '0' && code <= Char.toCode '9')
        || (code >= Char.toCode 'a' && code <= Char.toCode 'f')
        || (code >= Char.toCode 'A' && code <= Char.toCode 'F')
