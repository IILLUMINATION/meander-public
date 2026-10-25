import { handleUpload, type HandleUploadBody } from '@vercel/blob/client'
import { NextResponse } from 'next/server'
import { allowRequest } from '@/lib/rate-limit'

const MAX_QUEST_BYTES = 60 * 1024 * 1024

export async function POST(request: Request) {
  if (!allowRequest(request, 'upload', 10)) {
    return NextResponse.json({ error: 'Слишком много загрузок, попробуйте позже' }, { status: 429 })
  }
  const body = (await request.json()) as HandleUploadBody
  try {
    const json = await handleUpload({
      body,
      request,
      onBeforeGenerateToken: async (pathname) => {
        if (!/^uploads\/[^/]+\.mnd$/i.test(pathname)) {
          throw new Error('Можно загружать только .mnd файлы')
        }
        return {
          maximumSizeInBytes: MAX_QUEST_BYTES,
          addRandomSuffix: true,
        }
      },
    })
    return NextResponse.json(json)
  } catch (error) {
    return NextResponse.json({ error: (error as Error).message }, { status: 400 })
  }
}
