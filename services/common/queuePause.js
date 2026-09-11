// queuePause.js
// Purpose: Pause and resume the BullMQ queue during maintenance
// Depends on: services/common/queue.js
//
// Pausing is GLOBAL, not per-worker: BullMQ writes a paused marker into Redis,
// so every worker stops picking up new jobs, including ones that start later.
// That matters here - the HPA can spawn a new worker mid-maintenance, and a
// local-only pause would leave it happily draining the queue you meant to stop.
//
// Jobs already running are NOT killed. pause({ isPaused: true }) leaves them to
// finish, which is what you want: killing a half-finished job is how you get
// the partial writes maintenance mode was supposed to prevent.

const { createQueue } = require('./queue');

const QUEUE_NAME = 'jobs';

/**
 * Stop workers taking new jobs. In-flight jobs run to completion.
 * @returns {Promise<{paused: boolean, waiting: number, active: number}>}
 */
async function pauseQueues() {
  const queue = createQueue(QUEUE_NAME);
  try {
    await queue.pause();
    const counts = await queue.getJobCounts('waiting', 'active');
    return {
      paused: true,
      waiting: counts.waiting || 0,
      active: counts.active || 0,
    };
  } finally {
    await queue.close();
  }
}

/**
 * Resume normal processing.
 * @returns {Promise<{paused: boolean, waiting: number}>}
 */
async function resumeQueues() {
  const queue = createQueue(QUEUE_NAME);
  try {
    await queue.resume();
    const counts = await queue.getJobCounts('waiting');
    return { paused: false, waiting: counts.waiting || 0 };
  } finally {
    await queue.close();
  }
}

/**
 * Whether the queue is currently paused, and how much is waiting.
 * @returns {Promise<{paused: boolean, waiting: number, active: number}>}
 */
async function queueStatus() {
  const queue = createQueue(QUEUE_NAME);
  try {
    const paused = await queue.isPaused();
    const counts = await queue.getJobCounts('waiting', 'active');
    return {
      paused,
      waiting: counts.waiting || 0,
      active: counts.active || 0,
    };
  } finally {
    await queue.close();
  }
}

module.exports = { pauseQueues, resumeQueues, queueStatus, QUEUE_NAME };
