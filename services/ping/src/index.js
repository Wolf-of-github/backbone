// index.js
// Purpose: Minimal Express server for ping endpoint (now with auth)
// depends_on: []

const express = require('express');
const { requireAuth } = require('./common/authContext');

const app = express();
const PORT = process.env.PORT || 3000;

// Health check endpoint for k8s probes (no auth required)
app.get('/healthz', (req, res) => {
  res.status(200).json({ status: 'healthy' });
});

// Main ping endpoint (requires authentication)
app.get('/api/ping', requireAuth, (req, res) => {
  res.status(200).json({
    status: 'ok',
    timestamp: Date.now(),
    message: 'pong',
    user: {
      id: req.user.id,
      email: req.user.email
    }
  });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Ping service listening on port ${PORT}`);
});
