// failingJob.js
// Purpose: Example job handler that always fails (for testing retry logic)
// Depends on: None

async function failingJobHandler(job) {
  console.log(`Processing failing-job ${job.id} (attempt ${job.attemptsMade + 1}/${job.opts.attempts})`);

  // Always throw an error
  throw new Error('This job always fails for testing retry logic');
}

module.exports = failingJobHandler;
