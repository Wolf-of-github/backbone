// user.js
// Purpose: Mongoose User schema with argon2 password hashing
// Depends on: MongoDB connection from auth service

const mongoose = require('mongoose');

let argon2;
let bcrypt;

// Try to load argon2, fall back to bcrypt
try {
  argon2 = require('argon2');
} catch (e) {
  console.warn('argon2 not available, falling back to bcrypt');
  bcrypt = require('bcrypt');
}

const userSchema = new mongoose.Schema({
  email: {
    type: String,
    required: true,
    unique: true,
    lowercase: true,
    trim: true,
    index: true
  },
  passwordHash: {
    type: String,
    required: true,
    select: false  // Never selected by default
  },
  roles: {
    type: [String],
    default: ['user']
  }
}, {
  timestamps: true  // createdAt, updatedAt
});

// Pre-save hook: hash password if modified
userSchema.pre('save', async function(next) {
  // Only hash if password field was modified
  if (!this.isModified('passwordHash')) {
    return next();
  }

  try {
    if (argon2) {
      this.passwordHash = await argon2.hash(this.passwordHash);
    } else {
      this.passwordHash = await bcrypt.hash(this.passwordHash, 10);
    }
    next();
  } catch (err) {
    next(err);
  }
});

// Instance method: compare password
userSchema.methods.comparePassword = async function(candidatePassword) {
  try {
    if (argon2) {
      return await argon2.verify(this.passwordHash, candidatePassword);
    } else {
      return await bcrypt.compare(candidatePassword, this.passwordHash);
    }
  } catch (err) {
    console.error('Password comparison error:', err);
    return false;
  }
};

// Static method: find user by email with password
userSchema.statics.findByEmail = function(email) {
  return this.findOne({ email: email.toLowerCase() }).select('+passwordHash');
};

const User = mongoose.model('User', userSchema);

module.exports = User;
