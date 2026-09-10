// helloWorld.js
// Purpose: Example job handler - simple async task
// Depends on: None

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function helloWorldHandler(job) {
  const { name = 'World' } = job.data;

  console.log(`Processing hello-world job ${job.id} for ${name}`);

  // Simulate some work
  await sleep(2000);

  const result = {
    greeting: `Hello, ${name}!`,
    processedAt: new Date().toISOString(),
    jobId: job.id,
  };

  console.log(`Completed hello-world job ${job.id}`);

  return result;
}

module.exports = helloWorldHandler;
