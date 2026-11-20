import { bsc } from 'viem/chains'
export const CHAIN = bsc
export const PACTBOARD = (import.meta.env.VITE_PACTBOARD_ADDRESS ?? '0x50aF5b7d3a70f2F038b4E3baB20B3B9e7C899f17') as `0x${string}`
export const USDT = '0x55d398326f99059fF775485246999027B3197955' as const
export const AGENT_ID = '0x60b9262456de011f7d15a54cdd8c48baaa8b022f' as const
export const RPCS = (import.meta.env.VITE_RPC ? [import.meta.env.VITE_RPC as string] : ['https://bsc-dataseed.binance.org', 'https://bsc-rpc.publicnode.com', 'https://bsc-dataseed1.defibit.io'])
export const REPO_URL = (import.meta.env.VITE_REPO_URL ?? 'https://github.com/mozoraID/pactboard') as string
export const REVIEW_WINDOW_DAYS = 3
export const ANNOUNCEMENT = 'https://www.binance.com/en/support/announcement/detail/95f5dbe0ea674a48a739b59e046648bf'
