// jobs.js
// Purpose: REST API routes for job management
// Depends on: queue.js, authContext.js, Job model

const express = require('express');
const { v4: uuidv4 } = require('uuid');
const { requireAuth } = require('../common/authContext');
const { createQueue, JOB_TYPES } = require('../common/queue');
const Job = require('../models/job');

const router = express.Router();

// Initialize queue (singleton)
let queue;
function getQueue() {
  if (!queue) {
    queue = createQueue('jobs');
  }
  return queue;
}

// POST /api/jobs - Create a new job
router.post('/', requireAuth, async (req, res) => {
  try {
    const { type, data = {}, priority } = req.body;

    // Validate job type
    const validTypes = Object.values(JOB_TYPES);
    if (!type || !validTypes.includes(type)) {
      return res.status(400).json({
        error: 'Invalid job type',
        validTypes,
      });
    }

    // Generate unique job ID
    const jobId = uuidv4();
    const ownerId = req.user.id;

    // Create MongoDB record
    const job = await Job.create({
      jobId,
      ownerId,
      type,
      status: 'pending',
      data,
    });

    // Enqueue to BullMQ
    const bullQueue = getQueue();
    await bullQueue.add(
      type,
      {
        jobId,
        ownerId,
        ...data,
      },
      {
        jobId,
        priority: priority || 0,
      }
    );

    console.log(`Job ${jobId} (type: ${type}) created by user ${ownerId}`);

    res.status(201).json({
      jobId: job.jobId,
      status: job.status,
      type: job.type,
      createdAt: job.createdAt,
    });
  } catch (error) {
    console.error('Error creating job:', error);
    res.status(500).json({ error: 'Failed to create job' });
  }
});

// GET /api/jobs/:id - Get job status and result
router.get('/:id', requireAuth, async (req, res) => {
  try {
    const { id } = req.params;

    // Find job in MongoDB
    const job = await Job.findOne({ jobId: id });

    if (!job) {
      return res.status(404).json({ error: 'Job not found' });
    }

    // IDOR prevention: verify ownership
    if (job.ownerId !== req.user.id) {
      console.warn(`IDOR attempt: User ${req.user.id} tried to access job ${id} owned by ${job.ownerId}`);
      return res.status(403).json({ error: 'Forbidden' });
    }

    // Optionally merge latest state from BullMQ if job is still in Redis
    const bullQueue = getQueue();
    const bullJob = await bullQueue.getJob(id);

    let mergedStatus = job.status;
    let mergedProgress = job.progress;

    if (bullJob) {
      const bullState = await bullJob.getState();
      // Map BullMQ states to our status enum
      if (bullState === 'waiting' || bullState === 'delayed') {
        mergedStatus = 'pending';
      } else if (bullState === 'active') {
        mergedStatus = 'active';
        mergedProgress = bullJob.progress || 0;
      } else if (bullState === 'completed') {
        mergedStatus = 'completed';
      } else if (bullState === 'failed') {
        mergedStatus = 'failed';
      }
    }

    res.json({
      jobId: job.jobId,
      type: job.type,
      status: mergedStatus,
      progress: mergedProgress,
      data: job.data,
      result: job.result,
      createdAt: job.createdAt,
      updatedAt: job.updatedAt,
      completedAt: job.completedAt,
    });
  } catch (error) {
    console.error('Error fetching job:', error);
    res.status(500).json({ error: 'Failed to fetch job' });
  }
});

// GET /api/jobs - List user's jobs
router.get('/', requireAuth, async (req, res) => {
  try {
    const ownerId = req.user.id;
    const limit = Math.min(parseInt(req.query.limit) || 50, 100);
    const status = req.query.status; // Optional filter

    const query = { ownerId };
    if (status && ['pending', 'active', 'completed', 'failed'].includes(status)) {
      query.status = status;
    }

    const jobs = await Job.find(query)
      .sort({ createdAt: -1 })
      .limit(limit)
      .select('jobId type status progress createdAt updatedAt completedAt');

    res.json({
      jobs,
      count: jobs.length,
    });
  } catch (error) {
    console.error('Error listing jobs:', error);
    res.status(500).json({ error: 'Failed to list jobs' });
  }
});

module.exports = router;
