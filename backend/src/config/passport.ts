import passport from 'passport';
import { Strategy as GoogleStrategy } from 'passport-google-oauth20';
import pool from './database';
import { v4 as uuidv4 } from 'uuid';
import dotenv from 'dotenv';
import { publicUrl } from './public_host';

dotenv.config();

passport.use(
  new GoogleStrategy(
    {
      clientID: process.env.GOOGLE_CLIENT_ID!,
      clientSecret: process.env.GOOGLE_CLIENT_SECRET!,
      // Тот же хелпер, что у картинок: хвостовой слэш в BASE_URL не
      // должен давать `//auth/...` — Google сверяет redirect_uri буквально.
      callbackURL: publicUrl('/auth/google/callback'),
    },
    async (accessToken, refreshToken, profile, done) => {
      try {
        // Ищем пользователя в нашей БД по Google ID
        const existingUserResult = await pool.query('SELECT * FROM profiles WHERE google_id = $1', [profile.id]);

        if (existingUserResult.rows.length > 0) {
          // Пользователь уже существует, возвращаем его
          console.log('User found:', existingUserResult.rows[0].id);
          return done(null, existingUserResult.rows[0]);
        }

        // Если пользователя нет, создаем нового
        const newUser = {
          id: uuidv4(),
          google_id: profile.id,
          full_name: profile.displayName,
          email: profile.emails ? profile.emails[0].value : null,
          avatar_url: profile.photos ? profile.photos[0].value : null,
        };

        const newUserResult = await pool.query(
          'INSERT INTO profiles (id, google_id, full_name, email, avatar_url) VALUES ($1, $2, $3, $4, $5) RETURNING *',
          [newUser.id, newUser.google_id, newUser.full_name, newUser.email, newUser.avatar_url]
        );
        
        console.log('New user created:', newUserResult.rows[0].id);
        return done(null, newUserResult.rows[0]);
      } catch (err) {
        return done(err, false);
      }
    }
  )
);

// Эти функции нужны для express-session
passport.serializeUser((user: any, done) => {
    done(null, user.id);
});

passport.deserializeUser(async (id: string, done) => {
    try {
        const userResult = await pool.query('SELECT * FROM profiles WHERE id = $1', [id]);
        if (userResult.rows.length > 0) {
          done(null, userResult.rows[0]);
        } else {
          done(new Error('User not found'), null);
        }
    } catch(err) {
        done(err, null);
    }
});