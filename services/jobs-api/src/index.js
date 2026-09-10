// index.js
// Purpose: Main Express application for jobs-api
// Depends on: MongoDB, Redis, auth middleware

require('dotenv').config();
const express = require('express');
const mongoose = require('mongoose');

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(express.json());

// MongoDB connection
const MONGO_URI = `mongodb://${process.env.MONGO_APP_USER}:${process.env.MONGO_APP_PASSWORD}@${process.env.MONGO_HOST || 'mongodb.data.svc'}:${process.env.MONGO_PORT || 27017}/${process.env.MONGO_APP_DB}`;

mongoose.connect(MONGO_URI, {
  authSource: process.env.MONGO_APP_DB || 'backbone',
})
  .then(() => {
    console.log('Connected to MongoDB');
  })
  .catch((err) => {
    console.error('MongoDB connection error:', err);
    process.exit(1);
  });

// Health check endpoint
app.get('/healthz', (req, res) => {
  const mongoStatus = mongoose.connection.readyState === 1 ? 'connected' : 'disconnected';

  if (mongoStatus === 'connected') {
    res.status(200).json({ status: 'ok', mongo: mongoStatus });
  } else {
    res.status(503).json({ status: 'unhealthy', mongo: mongoStatus });
  }
});

// Mount routes
const jobsRouter = require('./routes/jobs');
app.use('/api/jobs', jobsRouter);

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Not found' });
});

// Error handler
app.use((err, req, res, next) => {
  console.error('Unhandled error:', err);
  res.status(500).json({ error: 'Internal server error' });
});

// Graceful shutdown
process.on('SIGTERM', async () => {
  console.log('SIGTERM received, closing connections...');
  await mongoose.connection.close();
  process.exit(0);
});

process.on('SIGINT', async () => {
  console.log('SIGINT received, closing connections...');
  await mongoose.connection.close();
  process.exit(0);
});

// Start server
app.listen(PORT, () => {
  console.log(`jobs-api listening on port ${PORT}`);
});
