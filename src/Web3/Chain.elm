module Web3.Chain exposing
    ( Chain
    , pulsechain
    , pulsechainTestnet
    , ethereum
    , sepolia
    , bsc
    , polygon
    , arbitrum
    , optimism
    , base
    , avalanche
    , zksync
    , fantom
    , gnosis
    , linea
    , scroll
    , custom
    , chainId
    , name
    , rpcUrl
    , blockExplorer
    )

{-| Chain definitions for EVM networks.

Each `Chain` bundles the chain ID, name, default RPC URL, block explorer URL,
and native currency symbol. Pass `Chain.chainId someChain` wherever a
`Web3.Types.ChainId` is needed (e.g. `Wallet.update` and `Wallet.switchChain`).

    import Web3.Chain as Chain
    import Web3.Wallet as Wallet

    expectedChain : Web3.Types.ChainId
    expectedChain =
        Chain.chainId Chain.pulsechain

    -- Add a network to the wallet (EIP-3085):
    addPulseChain : Web3.Wallet.WalletCmd
    addPulseChain =
        Wallet.addChain
            { chainId = 369
            , chainName = Chain.name Chain.pulsechain
            , rpcUrls = [ Chain.rpcUrl Chain.pulsechain ]
            , nativeCurrency = { name = "Pulse", symbol = "PLS", decimals = 18 }
            , blockExplorerUrls = [ Chain.blockExplorer Chain.pulsechain ]
            }

@docs Chain
@docs pulsechain, pulsechainTestnet, ethereum, sepolia
@docs bsc, polygon, arbitrum, optimism, base, avalanche, zksync, fantom, gnosis, linea, scroll
@docs custom
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

The block explorer URL points to scan.pulsechain.com served via Pinata's IPFS
gateway. This is the proper decentralised access method — the same explorer,
but fetched from IPFS rather than a centralised host.

-}
pulsechain : Chain
pulsechain =
    { chainId = T.chainId 369
    , name = "PulseChain"
    , rpcUrl = "https://rpc.pulsechain.com"
    , blockExplorer = "https://scan.mypinata.cloud/ipfs/bafybeienxyoyrhn5tswclvd3gdjy5mtkkwmu37aqtml6onbf7xnb3o22pe/#/address/"
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


{-| BNB Smart Chain mainnet (chain ID 56).
-}
bsc : Chain
bsc =
    { chainId = T.chainId 56
    , name = "BNB Smart Chain"
    , rpcUrl = "https://bsc-dataseed.binance.org"
    , blockExplorer = "https://bscscan.com"
    , nativeCurrency = "BNB"
    }


{-| Polygon PoS mainnet (chain ID 137).
-}
polygon : Chain
polygon =
    { chainId = T.chainId 137
    , name = "Polygon"
    , rpcUrl = "https://polygon-rpc.com"
    , blockExplorer = "https://polygonscan.com"
    , nativeCurrency = "POL"
    }


{-| Arbitrum One (chain ID 42161).
-}
arbitrum : Chain
arbitrum =
    { chainId = T.chainId 42161
    , name = "Arbitrum One"
    , rpcUrl = "https://arb1.arbitrum.io/rpc"
    , blockExplorer = "https://arbiscan.io"
    , nativeCurrency = "ETH"
    }


{-| Optimism (chain ID 10).
-}
optimism : Chain
optimism =
    { chainId = T.chainId 10
    , name = "Optimism"
    , rpcUrl = "https://mainnet.optimism.io"
    , blockExplorer = "https://optimistic.etherscan.io"
    , nativeCurrency = "ETH"
    }


{-| Base mainnet (chain ID 8453).
-}
base : Chain
base =
    { chainId = T.chainId 8453
    , name = "Base"
    , rpcUrl = "https://mainnet.base.org"
    , blockExplorer = "https://basescan.org"
    , nativeCurrency = "ETH"
    }


{-| Avalanche C-Chain (chain ID 43114).
-}
avalanche : Chain
avalanche =
    { chainId = T.chainId 43114
    , name = "Avalanche"
    , rpcUrl = "https://api.avax.network/ext/bc/C/rpc"
    , blockExplorer = "https://snowtrace.io"
    , nativeCurrency = "AVAX"
    }


{-| zkSync Era mainnet (chain ID 324).
-}
zksync : Chain
zksync =
    { chainId = T.chainId 324
    , name = "zkSync Era"
    , rpcUrl = "https://mainnet.era.zksync.io"
    , blockExplorer = "https://explorer.zksync.io"
    , nativeCurrency = "ETH"
    }


{-| Fantom Opera (chain ID 250).
-}
fantom : Chain
fantom =
    { chainId = T.chainId 250
    , name = "Fantom"
    , rpcUrl = "https://rpc.ankr.com/fantom"
    , blockExplorer = "https://ftmscan.com"
    , nativeCurrency = "FTM"
    }


{-| Gnosis Chain (chain ID 100).
-}
gnosis : Chain
gnosis =
    { chainId = T.chainId 100
    , name = "Gnosis"
    , rpcUrl = "https://rpc.gnosischain.com"
    , blockExplorer = "https://gnosisscan.io"
    , nativeCurrency = "xDAI"
    }


{-| Linea mainnet (chain ID 59144).
-}
linea : Chain
linea =
    { chainId = T.chainId 59144
    , name = "Linea"
    , rpcUrl = "https://rpc.linea.build"
    , blockExplorer = "https://lineascan.build"
    , nativeCurrency = "ETH"
    }


{-| Scroll mainnet (chain ID 534352).
-}
scroll : Chain
scroll =
    { chainId = T.chainId 534352
    , name = "Scroll"
    , rpcUrl = "https://rpc.scroll.io"
    , blockExplorer = "https://scrollscan.com"
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
