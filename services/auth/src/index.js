// index.js
// Purpose: Auth service entrypoint - Express server with Passport, MongoDB, Redis
// Depends on: all other auth service files

const express = require('express');
const mongoose = require('mongoose');
const cors = require('cors');
const helmet = require('helmet');
const { configurePassport } = require('./passport');
const tokenStore = require('./tokenStore');
const authRoutes = require('./routes/auth');
const maintenanceRoutes = require('./routes/maintenance');

const { instrumentHttp } = require('./common/metrics');

const app = express();

// Phase 5B: request timing + GET /metrics. Before the routes so the middleware
// sees every request.
instrumentHttp(app, { serviceName: 'auth' });
const PORT = process.env.PORT || 3000;

// Middleware
app.use(helmet());
app.use(express.json());

// CORS configuration
const frontendUrl = process.env.FRONTEND_URL || 'http://localhost:30080';
app.use(cors({
  origin: frontendUrl,
  credentials: true
}));

// Configure passport
const passport = configurePassport();
app.use(passport.initialize());

// Health check endpoint (must be before auth routes)
app.get('/healthz', (req, res) => {
  res.json({ status: 'healthy' });
});

// Mount auth routes
app.use('/api/auth', authRoutes);

// Admin-only maintenance control. Mounted at /internal so the gateway can keep
// it on the maintenance bypass list without exposing anything else - it is the
// escape hatch when the rest of the platform is returning 503.
app.use('/internal/maintenance', maintenanceRoutes);

// Error handling middleware
app.use((err, req, res, next) => {
  console.error('Unhandled error:', err);
  res.status(500).json({ error: 'Internal server error' });
});

// MongoDB connection
async function connectMongoDB() {
  const {
    MONGO_APP_USER,
    MONGO_APP_PASSWORD,
    MONGO_APP_DB
  } = process.env;

  if (!MONGO_APP_USER || !MONGO_APP_PASSWORD || !MONGO_APP_DB) {
    throw new Error('MongoDB credentials not provided. Set MONGO_APP_USER, MONGO_APP_PASSWORD, MONGO_APP_DB');
  }

  const mongoHost = process.env.MONGO_HOST || 'mongodb.data.svc';
  const mongoPort = process.env.MONGO_PORT || 27017;
  const mongoUri = `mongodb://${MONGO_APP_USER}:${MONGO_APP_PASSWORD}@${mongoHost}:${mongoPort}/${MONGO_APP_DB}?authSource=${MONGO_APP_DB}`;

  console.log(`Connecting to MongoDB at ${mongoHost}:${mongoPort}/${MONGO_APP_DB}...`);

  await mongoose.connect(mongoUri, {
    useNewUrlParser: true,
    useUnifiedTopology: true
  });

  console.log('Connected to MongoDB');
}

// Redis connection
async function connectRedis() {
  console.log('Connecting to Redis...');
  await tokenStore.connect();
  console.log('Redis connection verified');
}

// Graceful shutdown
process.on('SIGTERM', async () => {
  console.log('SIGTERM received, shutting down gracefully...');

  await tokenStore.disconnect();
  await mongoose.disconnect();

  process.exit(0);
});

process.on('SIGINT', async () => {
  console.log('SIGINT received, shutting down gracefully...');

  await tokenStore.disconnect();
  await mongoose.disconnect();

  process.exit(0);
});

// Start server
async function start() {
  try {
    // Connect to databases
    await connectMongoDB();
    await connectRedis();

    // Start HTTP server
    app.listen(PORT, '0.0.0.0', () => {
      console.log(`Auth service listening on port ${PORT}`);
      console.log(`CORS enabled for: ${frontendUrl}`);
    });
  } catch (err) {
    console.error('Failed to start auth service:', err);
    process.exit(1);
  }
}

start();
