// job.js
// Purpose: Mongoose schema for durable job storage
// Depends on: MongoDB from Phase 1

const mongoose = require('mongoose');

const jobSchema = new mongoose.Schema({
  jobId: {
    type: String,
    required: true,
    unique: true,
    index: true,
  },
  ownerId: {
    type: String,
    required: true,
    index: true,
  },
  type: {
    type: String,
    required: true,
  },
  status: {
    type: String,
    required: true,
    enum: ['pending', 'active', 'completed', 'failed'],
    default: 'pending',
    index: true,
  },
  data: {
    type: mongoose.Schema.Types.Mixed,
    default: {},
  },
  result: {
    type: mongoose.Schema.Types.Mixed,
  },
  progress: {
    type: Number,
    min: 0,
    max: 100,
    default: 0,
  },
  createdAt: {
    type: Date,
    default: Date.now,
  },
  updatedAt: {
    type: Date,
    default: Date.now,
  },
  completedAt: {
    type: Date,
  },
});

// Update updatedAt on save
jobSchema.pre('save', function(next) {
  this.updatedAt = new Date();
  next();
});

// Update updatedAt on findOneAndUpdate
jobSchema.pre('findOneAndUpdate', function(next) {
  this.set({ updatedAt: new Date() });
  next();
});

const Job = mongoose.model('Job', jobSchema);

module.exports = Job;
