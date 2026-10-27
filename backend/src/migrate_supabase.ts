import fs from 'fs';
import path from 'path';
import { Pool } from 'pg';
import dotenv from 'dotenv';

dotenv.config();

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});

const DATA_DIR = path.join(__dirname, '../migration_data');

const readJson = (filename: string) => {
  const filePath = path.join(DATA_DIR, filename);
  if (!fs.existsSync(filePath)) {
    console.warn(`⚠️ Файл ${filename} не найден, пропускаем.`);
    return [];
  }
  return JSON.parse(fs.readFileSync(filePath, 'utf-8'));
};

const migrate = async () => {
  const client = await pool.connect();
  try {
    console.log('🚀 Начинаем миграцию данных с сохранением UUID...');

    // ВНИМАНИЕ: этот скрипт работает с внешними данными из migration_data/.
    // Каталог migration_data/ намеренно не входит в публичный репозиторий.
    await client.query('BEGIN');

    const profiles = readJson('profiles.json');
    console.log(`👤 Импорт профилей: ${profiles.length}`);
    for (const p of profiles) {
      await client.query(`
        INSERT INTO profiles (id, full_name, avatar_url, created_at, role, bio, is_verified, ad_free_until, google_id, email)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        ON CONFLICT (id) DO UPDATE SET
          full_name = EXCLUDED.full_name,
          google_id = COALESCE(profiles.google_id, EXCLUDED.google_id),
          email = COALESCE(profiles.email, EXCLUDED.email);
      `, [p.id, p.full_name, p.avatar_url, p.created_at, p.role || 'user', p.bio, p.is_verified, p.ad_free_until, p.google_id, p.email]);
    }

    const quests = readJson('quests.json');
    console.log(`🧭 Импорт квестов: ${quests.length}`);
    for (const q of quests) {
      let status = q.status;
      if (!['in_review', 'published', 'rejected'].includes(status)) {
        status = 'in_review';
      }

      await client.query(`
        INSERT INTO quests (
          id, download_url, preview_image_url, title, description,
          downloads_count, version, created_at, updated_at, status,
          author_id, moderator_comment, category, is_featured,
          like_count, dislike_count, quest_size_bytes, node_count, estimated_playtime, is_demo,
          market_tier
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21)
        ON CONFLICT (id) DO NOTHING;
      `, [
        q.id, q.download_url, q.preview_image_url, q.title, q.description,
        q.downloads_count || 0, q.version || '1.0.0', q.created_at, q.updated_at, status,
        q.author_id, q.moderator_comment, q.category, q.is_featured || false,
        q.like_count || 0, q.dislike_count || 0, q.quest_size_bytes || 0, q.node_count || 0,
        q.estimated_playtime || 0, q.is_demo || q.demo || false,
        (q.is_demo || q.demo) ? 3 : ((q.is_featured && status === 'published') ? 1 : 2),
      ]);
    }

    const reviews = readJson('reviews.json');
    console.log(`💬 Импорт отзывов: ${reviews.length}`);
    for (const r of reviews) {
      let status = r.status;
      if (!['pending', 'approved', 'rejected'].includes(status)) status = 'approved';

      await client.query(`
        INSERT INTO reviews (id, quest_id, author_id, text_content, created_at, status)
        VALUES ($1, $2, $3, $4, $5, $6)
        ON CONFLICT (id) DO NOTHING;
      `, [r.id, r.quest_id, r.author_id, r.text_content, r.created_at, status]);
    }

    const ratings = readJson('ratings.json');
    console.log(`⭐ Импорт рейтингов: ${ratings.length}`);
    for (const r of ratings) {
      await client.query(`
        INSERT INTO ratings (quest_id, user_id, rating, created_at)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (quest_id, user_id) DO NOTHING;
      `, [r.quest_id, r.user_id, r.rating, r.created_at]);
    }

    const votes = readJson('quest_votes.json');
    console.log(`👍 Импорт лайков: ${votes.length}`);
    for (const v of votes) {
      await client.query(`
        INSERT INTO quest_votes (quest_id, user_id, is_like, created_at)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (quest_id, user_id) DO NOTHING;
      `, [v.quest_id, v.user_id, v.is_like, v.created_at]);
    }

    const screenshots = readJson('quest_screenshots.json');
    console.log(`🖼️ Импорт скриншотов: ${screenshots.length}`);
    for (const s of screenshots) {
      await client.query(`
        INSERT INTO quest_screenshots (id, quest_id, image_url, sort_order, created_at)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (id) DO NOTHING;
      `, [s.id, s.quest_id, s.image_url, s.sort_order, s.created_at]);
    }

    const downloads = readJson('quest_downloads.json');
    console.log(`📥 Импорт истории скачиваний: ${downloads.length}`);
    for (const d of downloads) {
      await client.query(`
        INSERT INTO quest_downloads (quest_id, user_id, downloaded_at)
        VALUES ($1, $2, $3)
        ON CONFLICT (user_id, quest_id) DO NOTHING;
      `, [d.quest_id, d.user_id, d.downloaded_at]);
    }

    const followers = readJson('user_followers.json');
    console.log(`👥 Импорт подписок: ${followers.length}`);
    for (const f of followers) {
      if (f.user_id && f.follower_id) {
        await client.query(`
          INSERT INTO user_followers (user_id, follower_id, created_at)
          VALUES ($1, $2, $3)
          ON CONFLICT (user_id, follower_id) DO NOTHING;
        `, [f.user_id, f.follower_id, f.created_at || new Date()]);
      }
    }

    const achievements = readJson('achievements.json');
    for (const a of achievements) {
      await client.query(`
        INSERT INTO achievements (id, name, description, icon_name, xp_reward, is_secret, category)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        ON CONFLICT (id) DO NOTHING;
      `, [a.id, a.name, a.description, a.icon_name, a.xp_reward || 10, a.is_secret || false, a.category || 'common']);
    }

    const userAchievements = readJson('user_achievements.json');
    console.log(`🏆 Импорт ачивок пользователей: ${userAchievements.length}`);
    for (const ua of userAchievements) {
      await client.query(`
        INSERT INTO user_achievements (user_id, achievement_id, achieved_at)
        VALUES ($1, $2, $3)
        ON CONFLICT (user_id, achievement_id) DO NOTHING;
      `, [ua.user_id, ua.achievement_id, ua.achieved_at]);
    }

    await client.query('COMMIT');
    console.log('✅ Миграция успешно завершена!');
  } catch (error) {
    await client.query('ROLLBACK');
    console.error('❌ Ошибка миграции:', error);
    process.exitCode = 1;
  } finally {
    client.release();
    await pool.end();
  }
};

migrate().catch((error) => {
  console.error('❌ Не удалось запустить миграцию:', error);
  process.exitCode = 1;
});
