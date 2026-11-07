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
        CORS_ORIGINS: "https://meander.sbs,https://www.meander.sbs"
      }
    }]
  }
