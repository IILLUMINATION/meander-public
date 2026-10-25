import 'server-only'

const WINDOW_MS = 10 * 60 * 1000
const MAX_KEYS = 10_000

// In-memory счётчик живёт в пределах одного инстанса Vercel: он не заменяет
// настоящую авторизацию, а только отсекает скриптовые всплески с одного IP.
const hits = new Map<string, number[]>()

function clientIp(request: Request): string {
  const forwarded = request.headers.get('x-forwarded-for')
  if (forwarded) return forwarded.split(',')[0].trim()
  return request.headers.get('x-real-ip') ?? 'unknown'
}

export function allowRequest(request: Request, bucket: string, limit: number): boolean {
  const now = Date.now()
  const key = `${bucket}:${clientIp(request)}`
  const recent = (hits.get(key) ?? []).filter((time) => now - time < WINDOW_MS)
  if (recent.length >= limit) {
    hits.set(key, recent)
    return false
  }
  recent.push(now)
  hits.set(key, recent)

  if (hits.size > MAX_KEYS) {
    for (const [candidate, times] of hits) {
      if (times.every((time) => now - time >= WINDOW_MS)) hits.delete(candidate)
    }
  }
  return true
}
