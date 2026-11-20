import { createPublicClient, fallback, http, parseAbi, formatUnits } from 'viem'
import { CHAIN, RPCS, PACTBOARD, USDT, AGENT_ID } from './config'
import pactboardAbi from './abi.json'

export const abi = pactboardAbi as any
export const erc20Abi = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address,address) view returns (uint256)',
  'function approve(address,uint256) returns (bool)',
])
export const agentAbi = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function handleOf(address) view returns (string)',
])

export const publicClient = createPublicClient({
  chain: CHAIN,
  transport: fallback(RPCS.map((u) => http(u, { timeout: 12_000 })), { rank: false }),
  batch: { multicall: true },
})

export enum Status { None, Open, Accepted, Submitted, Approved, Claimed, Rejected, Cancelled, Expired }
export const STATUS_LABEL: Record<number, string> = {
  0: 'None', 1: 'Open', 2: 'In progress', 3: 'In review', 4: 'Paid', 5: 'Paid (timeout)', 6: 'Rejected', 7: 'Cancelled', 8: 'Expired',
}
export type Job = {
  id: bigint
  poster: `0x${string}`
  worker: `0x${string}`
  reward: bigint
  deadline: bigint
  submittedAt: bigint
  status: Status
  title: string
  details: string
  result: string
}
export type Rep = { posted: number; paid: number; rejected: number; completed: number; failed: number; earned: bigint; spent: bigint }

export const fmtUsdt = (v: bigint) => {
  const s = formatUnits(v, 18)
  const [i, f = ''] = s.split('.')
  return `${Number(i).toLocaleString('en-US')}${f ? '.' + f.slice(0, 4).replace(/0+$/, '') : ''}`.replace(/\.$/, '')
}
export const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`

export async function isDeployed() {
  const code = await publicClient.getCode({ address: PACTBOARD })
  return !!code && code !== '0x'
}

export async function fetchJobs(offset = 0, limit = 60): Promise<Job[]> {
  const [ids, jobs] = (await publicClient.readContract({ address: PACTBOARD, abi, functionName: 'getJobs', args: [BigInt(offset), BigInt(limit)] })) as [bigint[], any[]]
  return jobs.map((j, i) => ({ ...j, id: ids[i], status: Number(j.status) }))
}
export async function fetchJob(id: bigint): Promise<Job> {
  const j = (await publicClient.readContract({ address: PACTBOARD, abi, functionName: 'getJob', args: [id] })) as any
  return { ...j, id, status: Number(j.status) }
}
export async function fetchJobCount(): Promise<bigint> {
  return (await publicClient.readContract({ address: PACTBOARD, abi, functionName: 'jobCount' })) as bigint
}
export async function fetchRep(addr: `0x${string}`): Promise<Rep> {
  const r = (await publicClient.readContract({ address: PACTBOARD, abi, functionName: 'reputation', args: [addr] })) as any
  return { posted: r[0], paid: r[1], rejected: r[2], completed: r[3], failed: r[4], earned: r[5], spent: r[6] }
}
const handleCache = new Map<string, string>()
export async function fetchHandle(addr: `0x${string}`): Promise<string> {
  const k = addr.toLowerCase()
  if (handleCache.has(k)) return handleCache.get(k)!
  try {
    const h = (await publicClient.readContract({ address: AGENT_ID, abi: agentAbi, functionName: 'handleOf', args: [addr] })) as string
    handleCache.set(k, h)
    return h
  } catch { return '' }
}
export async function hasAgentId(addr: `0x${string}`): Promise<boolean> {
  try { return ((await publicClient.readContract({ address: AGENT_ID, abi: agentAbi, functionName: 'balanceOf', args: [addr] })) as bigint) > 0n } catch { return false }
}
export const usdtBalance = (a: `0x${string}`) => publicClient.readContract({ address: USDT, abi: erc20Abi, functionName: 'balanceOf', args: [a] }) as Promise<bigint>
export const usdtAllowance = (a: `0x${string}`) => publicClient.readContract({ address: USDT, abi: erc20Abi, functionName: 'allowance', args: [a, PACTBOARD] }) as Promise<bigint>
