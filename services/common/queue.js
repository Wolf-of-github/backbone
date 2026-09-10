// queue.js
// Purpose: Shared BullMQ setup for job queue management
// Depends on: Redis from Phase 1

const { Queue, Worker, QueueEvents } = require('bullmq');
const Redis = require('ioredis');

// Job type constants
const JOB_TYPES = {
  HELLO_WORLD: 'hello-world',
  FAILING_JOB: 'failing-job',
};

// Default job options
const DEFAULT_JOB_OPTIONS = {
  attempts: 3,
  backoff: {
    type: 'exponential',
    delay: 2000,
  },
  removeOnComplete: 100,
  removeOnFail: 200,
};

// Create Redis connection
function createRedisConnection() {
  const redisHost = process.env.REDIS_HOST || 'redis.data.svc';
  const redisPort = parseInt(process.env.REDIS_PORT || '6379', 10);
  const redisPassword = process.env.REDIS_PASSWORD;

  if (!redisPassword) {
    throw new Error('REDIS_PASSWORD environment variable is required');
  }

  return new Redis({
    host: redisHost,
    port: redisPort,
    password: redisPassword,
    maxRetriesPerRequest: null, // Required for BullMQ
    retryStrategy: (times) => {
      const delay = Math.min(times * 50, 2000);
      return delay;
    },
  });
}

// Create a BullMQ Queue
function createQueue(name = 'jobs', opts = {}) {
  const connection = createRedisConnection();

  const queue = new Queue(name, {
    connection,
    defaultJobOptions: {
      ...DEFAULT_JOB_OPTIONS,
      ...opts.defaultJobOptions,
    },
  });

  queue.on('error', (err) => {
    console.error(`Queue ${name} error:`, err);
  });

  console.log(`Queue ${name} created, connected to Redis at ${connection.options.host}:${connection.options.port}`);

  return queue;
}

// Create a BullMQ Worker
function createWorker(name = 'jobs', processor, opts = {}) {
  const connection = createRedisConnection();

  const worker = new Worker(name, processor, {
    connection,
    concurrency: opts.concurrency || 5,
    ...opts,
  });

  worker.on('completed', (job) => {
    console.log(`Job ${job.id} completed successfully`);
  });

  worker.on('failed', (job, err) => {
    console.error(`Job ${job?.id} failed:`, err.message);
  });

  worker.on('error', (err) => {
    console.error(`Worker ${name} error:`, err);
  });

  console.log(`Worker ${name} started with concurrency ${opts.concurrency || 5}`);

  return worker;
}

// Create QueueEvents for listening to queue-level events
function createQueueEvents(name = 'jobs') {
  const connection = createRedisConnection();

  const queueEvents = new QueueEvents(name, {
    connection,
  });

  queueEvents.on('error', (err) => {
    console.error(`QueueEvents ${name} error:`, err);
  });

  console.log(`QueueEvents ${name} listening`);

  return queueEvents;
}

module.exports = {
  createQueue,
  createWorker,
  createQueueEvents,
  JOB_TYPES,
  DEFAULT_JOB_OPTIONS,
};
