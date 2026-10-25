import 'server-only'
import { unzipSync } from 'fflate'

const WORKFLOW_FILE = 'build_quest_apk.yml'
const FALLBACK_REFS = ['main']

export const repo = (process.env.GITHUB_REPO || 'IILLUMINATION/meander-public').trim()

export function isConfigured() {
  return Boolean(process.env.GITHUB_TOKEN) && /^[\w.-]+\/[\w.-]+$/.test(repo)
}

export class GitHubError extends Error {
  constructor(
    message: string,
    public status: number,
  ) {
    super(message)
  }
}

async function gh<T>(path: string, init: RequestInit = {}): Promise<T> {
  const token = process.env.GITHUB_TOKEN
  if (!token) throw new GitHubError('GITHUB_TOKEN не задан', 500)

  const res = await fetch(`https://api.github.com${path}`, {
    ...init,
    cache: 'no-store',
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${token}`,
      'X-GitHub-Api-Version': '2022-11-28',
      ...(init.body ? { 'Content-Type': 'application/json' } : {}),
      ...init.headers,
    },
  })

  if (!res.ok) {
    const body = await res.text()
    let message = body
    try {
      message = JSON.parse(body).message ?? body
    } catch {}
    throw new GitHubError(`GitHub ${res.status}: ${message}`, res.status)
  }
  if (res.status === 204) return undefined as T
  const text = await res.text()
  return (text ? JSON.parse(text) : undefined) as T
}

let cachedRef: string | null = null

async function resolveRef(): Promise<string> {
  if (cachedRef) return cachedRef
  const candidates = [process.env.GITHUB_BUILD_REF, ...FALLBACK_REFS].filter(
    (ref): ref is string => Boolean(ref),
  )
  for (const ref of candidates) {
    try {
      await gh(
        `/repos/${repo}/contents/.github/workflows/${WORKFLOW_FILE}?ref=${encodeURIComponent(ref)}`,
      )
      cachedRef = ref
      return ref
    } catch (error) {
      if (!(error instanceof GitHubError) || error.status !== 404) throw error
    }
  }
  throw new GitHubError(
    `Не найден .github/workflows/${WORKFLOW_FILE} ни в одной ветке: ${candidates.join(', ')}`,
    500,
  )
}

export async function uploadQuestBlob(bytes: Uint8Array): Promise<string> {
  const { sha } = await gh<{ sha: string }>(`/repos/${repo}/git/blobs`, {
    method: 'POST',
    body: JSON.stringify({
      content: Buffer.from(bytes).toString('base64'),
      encoding: 'base64',
    }),
  })
  return sha
}

export type DispatchInput = {
  requestId: string
  blobSha: string
  appName: string
  version: string
  abi: string
}

export async function dispatchBuild(input: DispatchInput): Promise<number | null> {
  const ref = await resolveRef()
  const result = await gh<{ workflow_run_id?: number } | undefined>(
    `/repos/${repo}/actions/workflows/${WORKFLOW_FILE}/dispatches`,
    {
      method: 'POST',
      body: JSON.stringify({
        ref,
        return_run_details: true,
        inputs: {
          request_id: input.requestId,
          quest_blob_sha: input.blobSha,
          app_name: input.appName,
          version: input.version,
          abi: input.abi,
        },
      }),
    },
  )
  return result?.workflow_run_id ?? null
}

type WorkflowRun = {
  id: number
  status: string
  conclusion: string | null
  display_title: string
  html_url: string
  created_at: string
}

export async function findRunId(requestId: string): Promise<number | null> {
  const { workflow_runs } = await gh<{ workflow_runs: WorkflowRun[] }>(
    `/repos/${repo}/actions/workflows/${WORKFLOW_FILE}/runs?event=workflow_dispatch&per_page=30`,
  )
  const run = workflow_runs.find((r) => r.display_title === `quest-apk ${requestId}`)
  return run?.id ?? null
}

export type RunState = {
  status: 'queued' | 'running' | 'success' | 'failure'
  htmlUrl: string
  currentStep: string | null
  completedSteps: number
  totalSteps: number
}

type Job = {
  steps?: { name: string; status: string; conclusion: string | null }[]
}

export async function getRunState(runId: number): Promise<RunState> {
  const run = await gh<WorkflowRun>(`/repos/${repo}/actions/runs/${runId}`)
  const { jobs } = await gh<{ jobs: Job[] }>(`/repos/${repo}/actions/runs/${runId}/jobs`)
  const steps = jobs[0]?.steps ?? []
  const active = steps.find((s) => s.status === 'in_progress')
  const failed = steps.find((s) => s.conclusion === 'failure')

  let status: RunState['status'] = 'running'
  if (run.status === 'completed') {
    status = run.conclusion === 'success' ? 'success' : 'failure'
  } else if (run.status === 'queued' || run.status === 'pending' || run.status === 'waiting') {
    status = 'queued'
  }

  return {
    status,
    htmlUrl: run.html_url,
    currentStep: (failed ?? active)?.name ?? null,
    completedSteps: steps.filter((s) => s.status === 'completed').length,
    totalSteps: steps.length,
  }
}

export async function downloadApkFromRun(
  runId: number,
): Promise<{ name: string; data: Uint8Array } | null> {
  const { artifacts } = await gh<{
    artifacts: { name: string; archive_download_url: string; expired: boolean }[]
  }>(`/repos/${repo}/actions/runs/${runId}/artifacts`)
  const artifact = artifacts.find((a) => a.name === 'quest-apk' && !a.expired)
  if (!artifact) return null

  const res = await fetch(artifact.archive_download_url, {
    headers: { Authorization: `Bearer ${process.env.GITHUB_TOKEN}` },
    redirect: 'follow',
    cache: 'no-store',
  })
  if (!res.ok) throw new GitHubError(`Не удалось скачать артефакт: ${res.status}`, res.status)

  const files = unzipSync(new Uint8Array(await res.arrayBuffer()))
  const apkName = Object.keys(files).find((name) => name.endsWith('.apk'))
  if (!apkName) return null
  return { name: apkName.split('/').pop() as string, data: files[apkName] }
}
