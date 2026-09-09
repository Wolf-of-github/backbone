// passport.js
// Purpose: Passport strategy configuration (local + JWT)
// Depends on: User model

const passport = require('passport');
const LocalStrategy = require('passport-local').Strategy;
const JwtStrategy = require('passport-jwt').Strategy;
const ExtractJwt = require('passport-jwt').ExtractJwt;
const fs = require('fs');
const User = require('./models/user');

// Load JWT keys from mounted secrets
function loadJwtKeys() {
  const privateKeyPath = '/secrets/jwt/private-key';
  const publicKeyPath = '/secrets/jwt/public-key';

  let privateKey = null;
  let publicKey = null;

  try {
    if (fs.existsSync(privateKeyPath)) {
      privateKey = fs.readFileSync(privateKeyPath, 'utf8');
    }
  } catch (err) {
    console.warn(`Could not load private key from ${privateKeyPath}:`, err.message);
  }

  try {
    if (fs.existsSync(publicKeyPath)) {
      publicKey = fs.readFileSync(publicKeyPath, 'utf8');
    }
  } catch (err) {
    console.warn(`Could not load public key from ${publicKeyPath}:`, err.message);
  }

  return { privateKey, publicKey };
}

// Configure passport strategies
function configurePassport() {
  const { publicKey } = loadJwtKeys();

  // Local strategy for login (email + password)
  passport.use(new LocalStrategy({
    usernameField: 'email',
    passwordField: 'password'
  }, async (email, password, done) => {
    try {
      // Find user with password field included
      const user = await User.findByEmail(email);

      if (!user) {
        return done(null, false, { message: 'Invalid email or password' });
      }

      // Verify password
      const isValid = await user.comparePassword(password);

      if (!isValid) {
        return done(null, false, { message: 'Invalid email or password' });
      }

      // Success - return user without passwordHash
      const userObj = user.toObject();
      delete userObj.passwordHash;

      return done(null, userObj);
    } catch (err) {
      console.error('Local strategy error:', err);
      return done(err);
    }
  }));

  // JWT strategy for protected routes
  if (publicKey) {
    const jwtOptions = {
      jwtFromRequest: ExtractJwt.fromAuthHeaderAsBearerToken(),
      secretOrKey: publicKey,
      algorithms: ['RS256']
    };

    passport.use(new JwtStrategy(jwtOptions, async (jwtPayload, done) => {
      try {
        // jwtPayload contains: sub (userId), email, roles, exp, iat
        const user = await User.findById(jwtPayload.sub);

        if (!user) {
          return done(null, false);
        }

        // Return user object without password
        const userObj = {
          id: user._id,
          email: user.email,
          roles: user.roles
        };

        return done(null, userObj);
      } catch (err) {
        console.error('JWT strategy error:', err);
        return done(err);
      }
    }));
  } else {
    console.warn('JWT public key not found - JWT strategy not configured');
  }

  return passport;
}

module.exports = {
  configurePassport,
  loadJwtKeys
};
