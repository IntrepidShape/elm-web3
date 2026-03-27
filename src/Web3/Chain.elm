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
-}

import Web3.Types as T


type alias Chain =
    { chainId : T.ChainId
    , name : String
    , rpcUrl : String
    , blockExplorer : String
    , nativeCurrency : String
    }


pulsechain : Chain
pulsechain =
    { chainId = T.chainId 369
    , name = "PulseChain"
    , rpcUrl = "https://rpc.pulsechain.com"
    , blockExplorer = "https://scan.pulsechain.com"
    , nativeCurrency = "PLS"
    }


pulsechainTestnet : Chain
pulsechainTestnet =
    { chainId = T.chainId 943
    , name = "PulseChain Testnet v4"
    , rpcUrl = "https://rpc.v4.testnet.pulsechain.com"
    , blockExplorer = "https://scan.v4.testnet.pulsechain.com"
    , nativeCurrency = "tPLS"
    }


ethereum : Chain
ethereum =
    { chainId = T.chainId 1
    , name = "Ethereum"
    , rpcUrl = "https://eth.llamarpc.com"
    , blockExplorer = "https://etherscan.io"
    , nativeCurrency = "ETH"
    }


sepolia : Chain
sepolia =
    { chainId = T.chainId 11155111
    , name = "Sepolia"
    , rpcUrl = "https://rpc.sepolia.org"
    , blockExplorer = "https://sepolia.etherscan.io"
    , nativeCurrency = "ETH"
    }


custom : { chainId : Int, name : String, rpcUrl : String, blockExplorer : String, nativeCurrency : String } -> Chain
custom opts =
    { chainId = T.chainId opts.chainId
    , name = opts.name
    , rpcUrl = opts.rpcUrl
    , blockExplorer = opts.blockExplorer
    , nativeCurrency = opts.nativeCurrency
    }


chainId : Chain -> T.ChainId
chainId chain =
    chain.chainId


name : Chain -> String
name chain =
    chain.name


rpcUrl : Chain -> String
rpcUrl chain =
    chain.rpcUrl


blockExplorer : Chain -> String
blockExplorer chain =
    chain.blockExplorer
