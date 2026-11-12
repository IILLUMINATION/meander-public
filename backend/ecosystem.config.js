// Домены для CORS берутся из `.env` (там же BASE_URL): переезд — правка
// одной строки в окружении, а не этого файла.
require('dotenv').config();

const PUBLIC_ORIGIN = process.env.SITE_ORIGIN || process.env.BASE_URL || 'https://meander.illuminat.dev';

module.exports = {
    apps : [{
      name   : "meander-backend",
      script : "./dist/app.js",
      instances: 1,
      autorestart: true,
      watch: false,
      max_memory_restart: '800M',
      env: {
        NODE_ENV: "production",
        CORS_ORIGINS: process.env.CORS_ORIGINS || `${PUBLIC_ORIGIN},https://illuminat.dev`
      }
    }]
  }
