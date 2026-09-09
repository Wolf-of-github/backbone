// App.jsx
// Purpose: Main React component - fetches /api/ping to prove end-to-end routing
// depends_on: []

import { useState, useEffect } from 'react';

function App() {
  const [backendStatus, setBackendStatus] = useState('Loading...');
  const [error, setError] = useState(null);

  useEffect(() => {
    fetch('/api/ping')
      .then((res) => {
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return res.json();
      })
      .then((data) => {
        setBackendStatus(`Backend status: ${data.status} (${data.message})`);
      })
      .catch((err) => {
        setError(`Error: ${err.message}`);
      });
  }, []);

  return (
    <div style={{ padding: '2rem', fontFamily: 'system-ui' }}>
      <h1>Backbone - Phase 2</h1>
      <p>React frontend served through Kong</p>
      <div style={{ marginTop: '2rem', padding: '1rem', background: '#f0f0f0', borderRadius: '4px' }}>
        {error ? (
          <p style={{ color: 'red' }}>{error}</p>
        ) : (
          <p style={{ color: 'green' }}>{backendStatus}</p>
        )}
      </div>
      <p style={{ marginTop: '2rem', color: '#666', fontSize: '0.9rem' }}>
        This page proves end-to-end routing: Kong routes / to this frontend and /api/* to backend services.
      </p>
    </div>
  );
}

export default App;
