module Web3.Chain exposing
    ( Chain
    , pulsechain
    , pulsechainTestnet
    , ethereum
    , sepolia
    , custom
    , chainId
    , name
    , rpcUrl
    , blockExplorer
    )

{-| Chain definitions for EVM networks.

@docs Chain
@docs pulsechain, pulsechainTestnet, ethereum, sepolia, custom
@docs chainId, name, rpcUrl, blockExplorer

-}

import Web3.Types as T


{-| An EVM chain definition.
-}
type alias Chain =
    { chainId : T.ChainId
    , name : String
    , rpcUrl : String
    , blockExplorer : String
    , nativeCurrency : String
    }


{-| PulseChain mainnet (chain ID 369).
-}
pulsechain : Chain
pulsechain =
    { chainId = T.chainId 369
    , name = "PulseChain"
    , rpcUrl = "https://rpc.pulsechain.com"
    , blockExplorer = "https://scan.mypinata.cloud/ipfs/bafybeienxyoyrhn5tswclvd3gdjy5mtkkwmu37aqtml6onbf7xnb3o22pe/#"
    , nativeCurrency = "PLS"
    }


{-| PulseChain testnet v4 (chain ID 943).
-}
pulsechainTestnet : Chain
pulsechainTestnet =
    { chainId = T.chainId 943
    , name = "PulseChain Testnet v4"
    , rpcUrl = "https://rpc.v4.testnet.pulsechain.com"
    , blockExplorer = "https://scan.v4.testnet.pulsechain.com"
    , nativeCurrency = "tPLS"
    }


{-| Ethereum mainnet (chain ID 1).
-}
ethereum : Chain
ethereum =
    { chainId = T.chainId 1
    , name = "Ethereum"
    , rpcUrl = "https://eth.llamarpc.com"
    , blockExplorer = "https://etherscan.io"
    , nativeCurrency = "ETH"
    }


{-| Sepolia testnet (chain ID 11155111).
-}
sepolia : Chain
sepolia =
    { chainId = T.chainId 11155111
    , name = "Sepolia"
    , rpcUrl = "https://rpc.sepolia.org"
    , blockExplorer = "https://sepolia.etherscan.io"
    , nativeCurrency = "ETH"
    }


{-| Define a custom EVM chain.
-}
custom : { chainId : Int, name : String, rpcUrl : String, blockExplorer : String, nativeCurrency : String } -> Chain
custom opts =
    { chainId = T.chainId opts.chainId
    , name = opts.name
    , rpcUrl = opts.rpcUrl
    , blockExplorer = opts.blockExplorer
    , nativeCurrency = opts.nativeCurrency
    }


{-| Get the chain ID.
-}
chainId : Chain -> T.ChainId
chainId chain =
    chain.chainId


{-| Get the chain name.
-}
name : Chain -> String
name chain =
    chain.name


{-| Get the RPC URL.
-}
rpcUrl : Chain -> String
rpcUrl chain =
    chain.rpcUrl


{-| Get the block explorer URL.
-}
blockExplorer : Chain -> String
blockExplorer chain =
    chain.blockExplorer
