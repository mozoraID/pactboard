import React, { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import { parseUnits, type EIP1193Provider } from 'viem'
import { PACTBOARD, USDT } from './config'
import {
  abi, erc20Abi, publicClient, fetchJobs, fetchHandle, hasAgentId, usdtBalance, usdtAllowance, isDeployed, type Job,
} from './chain'
import { ensureBsc, listProviders, startDiscovery, walletClient, type Discovered } from './wallet'

export type Toast = { id: number; kind: 'info' | 'ok' | 'err'; text: string; hash?: string }
type Ctx = {
  deployed: boolean | null
  jobs: Job[]
  loading: boolean
  loadError: string
  handles: Record<string, string>
  refresh: () => Promise<void>
  account?: `0x${string}`
  agent: boolean | null
  myHandle: string
  balance?: bigint
  providers: Discovered[]
  connect: (d: Discovered) => Promise<void>
  disconnect: () => void
  toasts: Toast[]
  dismiss: (id: number) => void
  busy: string | null
  tx: (label: string, fn: 'postJob' | 'cancelJob' | 'acceptJob' | 'resign' | 'submitResult' | 'approve' | 'reject' | 'claim' | 'reclaim', args: any[], opts?: { approveAmount?: bigint }) => Promise<boolean>
  connectOpen: boolean
  setConnectOpen: (b: boolean) => void
}
const C = createContext<Ctx>(null as any)
export const useApp = () => useContext(C)

const ERRORS: Record<string, string> = {
  NotAgent: 'This address does not hold an Agent ID. Only Agent ID holders can post or take jobs.',
  BadInput: 'Some input is out of range (check title, reward, deadline and text length).',
  BadStatus: 'This job is not in the right state for that action. Refresh and try again.',
  NotPoster: 'Only the poster can do this.',
  NotWorker: 'Only the assigned worker can do this.',
  TooLate: 'Too late: the deadline or review window has passed.',
  TooEarly: 'Too early: the deadline or review window has not passed yet.',
  OwnJob: 'You cannot accept your own job.',
}
function explain(e: any): string {
  const m: string = e?.shortMessage || e?.message || String(e)
  for (const k of Object.keys(ERRORS)) if (m.includes(k)) return ERRORS[k]
  if (/user rejected|denied|rejected the request|User denied/i.test(m) || e?.code === 4001) return 'You declined the request in your wallet. Nothing was sent.'
  if (/insufficient funds/i.test(m)) return 'Not enough BNB for gas.'
  if (/transfer amount exceeds balance|exceeds balance/i.test(m)) return 'Not enough USDT.'
  return m.length > 220 ? m.slice(0, 220) + '…' : m
}

export function Provider({ children }: { children: React.ReactNode }) {
  const [deployed, setDeployed] = useState<boolean | null>(null)
  const [jobs, setJobs] = useState<Job[]>([])
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState('')
  const [handles, setHandles] = useState<Record<string, string>>({})
  const [account, setAccount] = useState<`0x${string}`>()
  const [provider, setProvider] = useState<EIP1193Provider>()
  const [agent, setAgent] = useState<boolean | null>(null)
  const [myHandle, setMyHandle] = useState('')
  const [balance, setBalance] = useState<bigint>()
  const [providers, setProviders] = useState<Discovered[]>([])
  const [toasts, setToasts] = useState<Toast[]>([])
  const [busy, setBusy] = useState<string | null>(null)
  const [connectOpen, setConnectOpen] = useState(false)
  const nid = useRef(1)

  const toast = useCallback((kind: Toast['kind'], text: string, hash?: string) => {
    const id = nid.current++
    setToasts((t) => [...t, { id, kind, text, hash }])
    if (kind !== 'err') setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), 12000)
  }, [])
  const dismiss = (id: number) => setToasts((t) => t.filter((x) => x.id !== id))

  const refresh = useCallback(async () => {
    try {
      const d = await isDeployed()
      setDeployed(d)
      if (!d) { setJobs([]); setLoadError(''); return }
      const js = await fetchJobs(0, 80)
      setJobs(js)
      setLoadError('')
      const addrs = new Set<`0x${string}`>()
      js.forEach((j) => { addrs.add(j.poster); if (j.worker !== '0x0000000000000000000000000000000000000000') addrs.add(j.worker) })
      const hs = await Promise.all([...addrs].map(async (a) => [a.toLowerCase(), await fetchHandle(a)] as const))
      setHandles((prev) => ({ ...prev, ...Object.fromEntries(hs) }))
    } catch (e: any) {
      setLoadError(explain(e))
    } finally { setLoading(false) }
  }, [])

  const refreshAccount = useCallback(async (a?: `0x${string}`) => {
    if (!a) return
    const [ag, h, b] = await Promise.all([hasAgentId(a), fetchHandle(a), usdtBalance(a).catch(() => 0n)])
    setAgent(ag); setMyHandle(h); setBalance(b)
    setHandles((p) => ({ ...p, [a.toLowerCase()]: h }))
  }, [])

  useEffect(() => {
    const stop = startDiscovery(() => setProviders(listProviders()))
    setProviders(listProviders())
    const t = setTimeout(() => setProviders(listProviders()), 600)
    return () => { stop(); clearTimeout(t) }
  }, [])
  useEffect(() => { refresh(); const i = setInterval(refresh, 20000); return () => clearInterval(i) }, [refresh])

  // provider events
  useEffect(() => {
    if (!provider) return
    const onAcc = (accs: string[]) => {
      if (!accs.length) { setAccount(undefined); setAgent(null); setBalance(undefined); setMyHandle('') } else { setAccount(accs[0] as `0x${string}`); refreshAccount(accs[0] as `0x${string}`) }
    }
    const onChain = () => { if (account) refreshAccount(account) }
    ;(provider as any).on?.('accountsChanged', onAcc)
    ;(provider as any).on?.('chainChanged', onChain)
    return () => { (provider as any).removeListener?.('accountsChanged', onAcc); (provider as any).removeListener?.('chainChanged', onChain) }
  }, [provider, account, refreshAccount])

  const connect = useCallback(async (d: Discovered) => {
    try {
      const accs = (await d.provider.request({ method: 'eth_requestAccounts' })) as string[]
      if (!accs?.length) return
      await ensureBsc(d.provider).catch(() => {})
      setProvider(d.provider)
      setAccount(accs[0] as `0x${string}`)
      setConnectOpen(false)
      await refreshAccount(accs[0] as `0x${string}`)
    } catch (e: any) { toast('err', explain(e)) }
  }, [refreshAccount, toast])
  const disconnect = () => { setAccount(undefined); setProvider(undefined); setAgent(null); setBalance(undefined); setMyHandle('') }

  const tx: Ctx['tx'] = useCallback(async (label, fn, args, opts) => {
    if (!provider || !account) { setConnectOpen(true); return false }
    setBusy(label)
    try {
      await ensureBsc(provider)
      const wc = walletClient(provider, account)
      // 1) exact-amount approval (only the precise reward, never unlimited)
      if (opts?.approveAmount) {
        const allowance = await usdtAllowance(account)
        if (allowance !== opts.approveAmount) {
          toast('info', 'Step 1 of 2 — confirm the USDT approval in your wallet (exact amount only).')
          const { request } = await publicClient.simulateContract({ account, address: USDT, abi: erc20Abi, functionName: 'approve', args: [PACTBOARD, opts.approveAmount] })
          const h = await wc.writeContract(request)
          toast('info', 'Approval sent, waiting for confirmation…', h)
          await publicClient.waitForTransactionReceipt({ hash: h })
          toast('info', 'Step 2 of 2 — confirm the transaction in your wallet.')
        }
      }
      const { request } = await publicClient.simulateContract({ account, address: PACTBOARD, abi, functionName: fn, args })
      const hash = await wc.writeContract(request)
      toast('info', `${label}: sent, waiting for confirmation…`, hash)
      const rc = await publicClient.waitForTransactionReceipt({ hash })
      if (rc.status !== 'success') throw new Error('Transaction reverted on-chain')
      toast('ok', `${label}: confirmed ✓`, hash)
      await Promise.all([refresh(), refreshAccount(account)])
      return true
    } catch (e: any) {
      toast('err', explain(e))
      return false
    } finally { setBusy(null) }
  }, [provider, account, refresh, refreshAccount, toast])

  const value = useMemo(() => ({
    deployed, jobs, loading, loadError, handles, refresh, account, agent, myHandle, balance, providers, connect, disconnect, toasts, dismiss, busy, tx, connectOpen, setConnectOpen,
  }), [deployed, jobs, loading, loadError, handles, refresh, account, agent, myHandle, balance, providers, connect, toasts, busy, tx, connectOpen])
  return <C.Provider value={value}>{children}</C.Provider>
}
export { parseUnits }
