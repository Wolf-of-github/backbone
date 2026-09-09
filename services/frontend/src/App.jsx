// App.jsx
// Purpose: Main React component with authentication (Phase 3)
// depends_on: []

import { useState, useEffect } from 'react';
import Login from './components/Login';
import Register from './components/Register';

// Helper: Fetch with auth and auto-refresh
async function authFetch(url, options = {}) {
  const accessToken = localStorage.getItem('accessToken');

  if (!accessToken) {
    throw new Error('No access token');
  }

  // Add Authorization header
  const headers = {
    ...options.headers,
    'Authorization': `Bearer ${accessToken}`
  };

  let res = await fetch(url, { ...options, headers });

  // If 401, try to refresh token
  if (res.status === 401) {
    const refreshToken = localStorage.getItem('refreshToken');

    if (!refreshToken) {
      throw new Error('No refresh token');
    }

    // Attempt refresh
    const refreshRes = await fetch('/api/auth/refresh', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ refreshToken })
    });

    if (!refreshRes.ok) {
      // Refresh failed - clear tokens
      localStorage.removeItem('accessToken');
      localStorage.removeItem('refreshToken');
      throw new Error('Session expired');
    }

    const refreshData = await refreshRes.json();
    localStorage.setItem('accessToken', refreshData.accessToken);
    localStorage.setItem('refreshToken', refreshData.refreshToken);

    // Retry original request with new token
    headers.Authorization = `Bearer ${refreshData.accessToken}`;
    res = await fetch(url, { ...options, headers });
  }

  return res;
}

function App() {
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const [showRegister, setShowRegister] = useState(false);
  const [user, setUser] = useState(null);
  const [backendStatus, setBackendStatus] = useState('Loading...');
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(true);

  // Check authentication on mount
  useEffect(() => {
    const checkAuth = async () => {
      const accessToken = localStorage.getItem('accessToken');

      if (!accessToken) {
        setLoading(false);
        return;
      }

      try {
        const res = await authFetch('/api/auth/me');

        if (!res.ok) {
          throw new Error('Authentication failed');
        }

        const userData = await res.json();
        setUser(userData);
        setIsAuthenticated(true);
      } catch (err) {
        // Clear invalid tokens
        localStorage.removeItem('accessToken');
        localStorage.removeItem('refreshToken');
      } finally {
        setLoading(false);
      }
    };

    checkAuth();
  }, []);

  // Fetch backend status when authenticated
  useEffect(() => {
    if (!isAuthenticated) return;

    const fetchPing = async () => {
      try {
        const res = await authFetch('/api/ping');

        if (!res.ok) {
          throw new Error(`HTTP ${res.status}`);
        }

        const data = await res.json();
        setBackendStatus(`Backend status: ${data.status} (${data.message}) - User: ${data.user?.email || 'unknown'}`);
        setError(null);
      } catch (err) {
        setError(`Error: ${err.message}`);
      }
    };

    fetchPing();
  }, [isAuthenticated]);

  const handleLoginSuccess = () => {
    setIsAuthenticated(true);
    setShowRegister(false);
    window.location.reload(); // Reload to fetch user data
  };

  const handleLogout = async () => {
    const refreshToken = localStorage.getItem('refreshToken');

    if (refreshToken) {
      try {
        await fetch('/api/auth/logout', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ refreshToken })
        });
      } catch (err) {
        console.error('Logout error:', err);
      }
    }

    localStorage.removeItem('accessToken');
    localStorage.removeItem('refreshToken');
    setIsAuthenticated(false);
    setUser(null);
  };

  if (loading) {
    return <div style={{ padding: '2rem', fontFamily: 'system-ui' }}>Loading...</div>;
  }

  if (!isAuthenticated) {
    return (
      <div style={{ padding: '2rem', fontFamily: 'system-ui' }}>
        <h1>Backbone - Phase 3 (Auth)</h1>
        {showRegister ? (
          <Register onSwitchToLogin={() => setShowRegister(false)} />
        ) : (
          <Login onLoginSuccess={handleLoginSuccess} onSwitchToRegister={() => setShowRegister(true)} />
        )}
      </div>
    );
  }

  return (
    <div style={{ padding: '2rem', fontFamily: 'system-ui' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <h1>Backbone - Phase 3 (Auth)</h1>
        <div>
          <span style={{ marginRight: '1rem' }}>Welcome, {user?.email}</span>
          <button
            onClick={handleLogout}
            style={{
              padding: '0.5rem 1rem',
              background: '#dc3545',
              color: 'white',
              border: 'none',
              borderRadius: '4px',
              cursor: 'pointer'
            }}
          >
            Logout
          </button>
        </div>
      </div>
      <p>Authenticated React frontend with JWT tokens</p>
      <div style={{ marginTop: '2rem', padding: '1rem', background: '#f0f0f0', borderRadius: '4px' }}>
        {error ? (
          <p style={{ color: 'red' }}>{error}</p>
        ) : (
          <p style={{ color: 'green' }}>{backendStatus}</p>
        )}
      </div>
      <p style={{ marginTop: '2rem', color: '#666', fontSize: '0.9rem' }}>
        This page proves end-to-end authentication: Kong routes requests, auth service issues JWT tokens,
        and backend services (like /api/ping) require valid tokens.
      </p>
    </div>
  );
}

export default App;
