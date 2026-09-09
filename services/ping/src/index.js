// index.js
// Purpose: Minimal Express server for ping endpoint
// depends_on: []

const express = require('express');

const app = express();
const PORT = process.env.PORT || 3000;

// Health check endpoint for k8s probes
app.get('/healthz', (req, res) => {
  res.status(200).json({ status: 'healthy' });
});

// Main ping endpoint
app.get('/api/ping', (req, res) => {
  res.status(200).json({
    status: 'ok',
    timestamp: Date.now(),
    message: 'pong'
  });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Ping service listening on port ${PORT}`);
});
