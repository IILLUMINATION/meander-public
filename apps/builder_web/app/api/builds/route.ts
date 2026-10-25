import { del, get } from '@vercel/blob'
import { NextResponse } from 'next/server'
import { listBuilds, saveBuild, type BuildRecord } from '@/lib/builds'
import { dispatchBuild, GitHubError, isConfigured, uploadQuestBlob } from '@/lib/github'
import { allowRequest } from '@/lib/rate-limit'

export const maxDuration = 60

const ABIS = ['arm64', 'arm', 'x64', 'all'] as const

function bad(message: string, status = 400) {
  return NextResponse.json({ error: message }, { status })
}

export async function GET() {
  if (!isConfigured()) return NextResponse.json({ builds: [] })
  return NextResponse.json({ builds: await listBuilds() })
}

export async function POST(request: Request) {
  if (!isConfigured()) return bad('Сборщик не настроен: добавь GITHUB_TOKEN', 500)
  if (!allowRequest(request, 'build', 5)) return bad('Слишком много сборок, попробуйте позже', 429)

  const body = (await request.json().catch(() => null)) as {
    pathname?: unknown
    fileName?: unknown
    appName?: unknown
    version?: unknown
    abi?: unknown
  } | null
  if (!body) return bad('Пустой запрос')

  const pathname = typeof body.pathname === 'string' ? body.pathname : ''
  const fileName = typeof body.fileName === 'string' ? body.fileName.slice(0, 120) : 'quest.mnd'
  const appName = typeof body.appName === 'string' ? body.appName.trim().slice(0, 60) : ''
  const version = typeof body.version === 'string' ? body.version.trim() : '1.0.0'
  const abi = typeof body.abi === 'string' ? body.abi : 'arm64'

  if (!/^uploads\/[^/]+\.mnd$/i.test(pathname)) return bad('Неверный файл квеста')
  if (!appName) return bad('Укажи название приложения')
  if (!/^\d+(\.\d+){0,3}$/.test(version)) return bad('Версия должна быть вида 1.0.0')
  if (!ABIS.includes(abi as (typeof ABIS)[number])) return bad('Неизвестная архитектура')

  const file = await get(pathname, { access: 'private' })
  if (!file || file.statusCode !== 200) return bad('Загруженный файл не найден', 404)
  const bytes = new Uint8Array(await new Response(file.stream).arrayBuffer())

  const header = new TextDecoder().decode(bytes.slice(0, 8))
  const isZip = bytes[0] === 0x50 && bytes[1] === 0x4b
  if (!header.startsWith('MND_') && !isZip) {
    await del(pathname)
    return bad('Это не похоже на квест .mnd')
  }

  const id = crypto.randomUUID().replace(/-/g, '').slice(0, 16)
  try {
    const blobSha = await uploadQuestBlob(bytes)
    const runId = await dispatchBuild({ requestId: id, blobSha, appName, version, abi })
    const record: BuildRecord = {
      id,
      appName,
      fileName,
      version,
      abi,
      createdAt: new Date().toISOString(),
      runId,
      apkPathname: null,
      apkName: null,
      apkSize: null,
    }
    await saveBuild(record)
    return NextResponse.json({ id })
  } catch (error) {
    const status = error instanceof GitHubError ? error.status : 500
    const hint =
      status === 403 || status === 401
        ? ' — у токена нет прав Actions: Read and write и Contents: Read and write'
        : ''
    return bad(`${(error as Error).message}${hint}`, status >= 500 ? 502 : status)
  } finally {
    await del(pathname).catch(() => {})
  }
}
