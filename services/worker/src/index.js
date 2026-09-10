// index.js
// Purpose: BullMQ worker that processes jobs from the queue
// Depends on: Redis, MongoDB, job handlers

require('dotenv').config();
const http = require('http');
const mongoose = require('mongoose');
const { createWorker, JOB_TYPES } = require('./common/queue');
const Job = require('./models/job');

// Import job handlers
const helloWorldHandler = require('./handlers/helloWorld');
const failingJobHandler = require('./handlers/failingJob');

// Map job types to handlers
const handlers = {
  [JOB_TYPES.HELLO_WORLD]: helloWorldHandler,
  [JOB_TYPES.FAILING_JOB]: failingJobHandler,
};

// MongoDB connection
const MONGO_URI = `mongodb://${process.env.MONGO_APP_USER}:${process.env.MONGO_APP_PASSWORD}@${process.env.MONGO_HOST || 'mongodb.data.svc'}:${process.env.MONGO_PORT || 27017}/${process.env.MONGO_APP_DB}`;

mongoose.connect(MONGO_URI, {
  authSource: process.env.MONGO_APP_DB || 'backbone',
})
  .then(() => {
    console.log('Worker connected to MongoDB');
  })
  .catch((err) => {
    console.error('MongoDB connection error:', err);
    process.exit(1);
  });

// Worker state
let worker;
let isRunning = false;

// Job processor function
async function processJob(job) {
  const handler = handlers[job.name];

  if (!handler) {
    throw new Error(`Unknown job type: ${job.name}`);
  }

  console.log(`Processing job ${job.id} (type: ${job.name})`);

  // Update job status to active
  await Job.updateOne(
    { jobId: job.id },
    {
      status: 'active',
      updatedAt: new Date(),
    }
  );

  try {
    // Execute the handler
    const result = await handler(job);

    // Update job status to completed
    await Job.updateOne(
      { jobId: job.id },
      {
        status: 'completed',
        result,
        completedAt: new Date(),
        updatedAt: new Date(),
      }
    );

    console.log(`Job ${job.id} completed successfully`);

    return result;
  } catch (error) {
    console.error(`Job ${job.id} failed:`, error.message);

    // Update job status to failed
    await Job.updateOne(
      { jobId: job.id },
      {
        status: 'failed',
        result: {
          error: error.message,
          stack: error.stack,
        },
        updatedAt: new Date(),
      }
    );

    throw error;
  }
}

// Create and start the worker
const concurrency = parseInt(process.env.WORKER_CONCURRENCY || '5', 10);

worker = createWorker('jobs', processJob, {
  concurrency,
});

worker.on('ready', () => {
  isRunning = true;
  console.log('Worker is ready and processing jobs');
});

worker.on('error', (err) => {
  console.error('Worker error:', err);
});

// Simple HTTP server for health checks
const healthServer = http.createServer((req, res) => {
  if (req.url === '/healthz') {
    const mongoStatus = mongoose.connection.readyState === 1 ? 'connected' : 'disconnected';
    const workerStatus = isRunning ? 'running' : 'stopped';

    if (mongoStatus === 'connected' && workerStatus === 'running') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'ok', mongo: mongoStatus, worker: workerStatus }));
    } else {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'unhealthy', mongo: mongoStatus, worker: workerStatus }));
    }
  } else {
    res.writeHead(404);
    res.end('Not Found');
  }
});

healthServer.listen(3000, () => {
  console.log('Health check server listening on port 3000');
});

// Graceful shutdown
async function shutdown(signal) {
  console.log(`${signal} received, starting graceful shutdown...`);
  isRunning = false;

  // Close the worker (drains in-flight jobs)
  if (worker) {
    console.log('Closing worker, draining in-flight jobs...');
    await worker.close();
    console.log('Worker closed');
  }

  // Close MongoDB connection
  await mongoose.connection.close();
  console.log('MongoDB connection closed');

  // Close health server
  healthServer.close(() => {
    console.log('Health server closed');
    process.exit(0);
  });

  // Force exit after 30 seconds if graceful shutdown fails
  setTimeout(() => {
    console.error('Graceful shutdown timeout, forcing exit');
    process.exit(1);
  }, 30000);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

console.log(`Worker started with concurrency ${concurrency}`);
