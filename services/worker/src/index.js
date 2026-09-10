// index.js
// Purpose: BullMQ worker that processes jobs from the queue
// Depends on: Redis, MongoDB, job handlers

require('dotenv').config();
const http = require('http');
const mongoose = require('mongoose');
const { createWorker, createQueue, JOB_TYPES } = require('./common/queue');
const {
  register,
  jobsProcessed,
  jobsFailed,
  jobDuration,
  trackQueueDepth,
} = require('./common/metrics');
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

  // Phase 5B: time the handler itself, labelled by job type.
  const endTimer = jobDuration.startTimer({ type: job.name });

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

    endTimer();
    jobsProcessed.inc({ type: job.name });

    console.log(`Job ${job.id} completed successfully`);

    return result;
  } catch (error) {
    endTimer();
    // Counts every failed ATTEMPT, including ones BullMQ will retry - the
    // failure-rate alert is meant to catch a handler that is flapping, not
    // only jobs that have exhausted all three attempts.
    jobsFailed.inc({ type: job.name });

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

// Phase 5B: publish queue depth (waiting/active/delayed/failed) as a gauge.
// This is what the JobQueueBacklog alert reads, and what a future queue-depth
// HPA would scale on. Polled, not event-driven - depth is a level, and a
// missed event would leave the gauge permanently wrong.
const metricsQueue = createQueue('jobs');
const stopQueueTracking = trackQueueDepth(metricsQueue, { queueName: 'jobs' });

worker.on('ready', () => {
  isRunning = true;
  console.log('Worker is ready and processing jobs');
});

worker.on('error', (err) => {
  console.error('Worker error:', err);
});

// Simple HTTP server for health checks (and, since Phase 5B, /metrics).
const healthServer = http.createServer(async (req, res) => {
  if (req.url === '/metrics') {
    res.writeHead(200, { 'Content-Type': register.contentType });
    res.end(await register.metrics());
    return;
  }
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

  // Stop polling queue depth before tearing down the Redis connections, or the
  // final poll races the close and logs a spurious error.
  stopQueueTracking();
  await metricsQueue.close();

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
