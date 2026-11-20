import { createWalletClient, custom, type EIP1193Provider } from 'viem'
import { CHAIN } from './config'

export type Discovered = { uuid: string; name: string; icon: string; provider: EIP1193Provider }
const found = new Map<string, Discovered>()

export function startDiscovery(onChange: () => void) {
  const handler = (e: any) => {
    const d = e.detail
    if (d?.info && d?.provider) { found.set(d.info.uuid, { uuid: d.info.uuid, name: d.info.name, icon: d.info.icon, provider: d.provider }); onChange() }
  }
  window.addEventListener('eip6963:announceProvider', handler)
  window.dispatchEvent(new Event('eip6963:requestProvider'))
  return () => window.removeEventListener('eip6963:announceProvider', handler)
}
export function listProviders(): Discovered[] {
  const list = [...found.values()]
  const w = window as any
  if (w.ethereum && !list.some((d) => d.provider === w.ethereum)) {
    list.push({ uuid: 'window.ethereum', name: w.ethereum.isBinance ? 'Binance Wallet' : 'Browser wallet', icon: '', provider: w.ethereum })
  }
  // Binance Wallet's dedicated injection
  if (w.binancew3w?.ethereum && !list.some((d) => d.provider === w.binancew3w.ethereum)) {
    list.unshift({ uuid: 'binancew3w', name: 'Binance Wallet', icon: '', provider: w.binancew3w.ethereum })
  }
  return list.sort((a, b) => (/binance/i.test(b.name) ? 1 : 0) - (/binance/i.test(a.name) ? 1 : 0))
}

export async function ensureBsc(provider: EIP1193Provider) {
  const chainId = (await provider.request({ method: 'eth_chainId' })) as string
  if (parseInt(chainId, 16) === CHAIN.id) return
  try {
    await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0x38' }] })
  } catch (e: any) {
    if (e?.code === 4902 || /unrecognized|not added/i.test(e?.message ?? '')) {
      await provider.request({
        method: 'wallet_addEthereumChain',
        params: [{ chainId: '0x38', chainName: 'BNB Smart Chain', nativeCurrency: { name: 'BNB', symbol: 'BNB', decimals: 18 }, rpcUrls: ['https://bsc-dataseed.binance.org'], blockExplorerUrls: ['https://bscscan.com'] }],
      })
    } else throw e
  }
}
export function walletClient(provider: EIP1193Provider, account: `0x${string}`) {
  return createWalletClient({ account, chain: CHAIN, transport: custom(provider) })
}
