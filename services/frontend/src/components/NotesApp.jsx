// NotesApp.jsx
// Purpose: Notes CRUD demo view. Create enqueues a job on the "notes"
// BullMQ queue via notes-api; notes-worker (a separate Python process)
// processes it and writes to MongoDB - polling a just-created note here
// makes that async handoff ("pending" -> "completed") visible in the UI.
// depends_on: [App.jsx's authFetch]

import { useState, useEffect, useRef } from 'react';

function NotesApp({ authFetch }) {
  const [notes, setNotes] = useState([]);
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [error, setError] = useState(null);
  const [creating, setCreating] = useState(false);
  const pollTimers = useRef({});

  const loadNotes = async () => {
    try {
      const res = await authFetch('/api/notes');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      setNotes(data.notes);
      setError(null);
    } catch (err) {
      setError(err.message);
    }
  };

  useEffect(() => {
    loadNotes();
    return () => {
      Object.values(pollTimers.current).forEach(clearInterval);
    };
  }, []);

  const pollUntilComplete = (pendingId) => {
    pollTimers.current[pendingId] = setInterval(async () => {
      try {
        const res = await authFetch(`/api/notes/${pendingId}`);
        if (!res.ok) return;
        const note = await res.json();
        setNotes((prev) =>
          prev.map((n) => (n.id === pendingId ? { ...note, id: note.id } : n))
        );
        if (note.status === 'completed') {
          clearInterval(pollTimers.current[pendingId]);
          delete pollTimers.current[pendingId];
          loadNotes(); // pick up the real _id once it exists
        }
      } catch {
        // transient - next tick retries
      }
    }, 1500);
  };

  const handleCreate = async (e) => {
    e.preventDefault();
    setCreating(true);
    setError(null);
    try {
      const res = await authFetch('/api/notes', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ title, body })
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Create failed');

      // Shown immediately as "pending" - it does not exist in MongoDB yet,
      // only in this response and the BullMQ queue.
      setNotes((prev) => [
        { id: data.pendingId, title, body, status: 'pending' },
        ...prev
      ]);
      setTitle('');
      setBody('');
      pollUntilComplete(data.pendingId);
    } catch (err) {
      setError(err.message);
    } finally {
      setCreating(false);
    }
  };

  return (
    <div>
      <p style={{ color: '#666' }}>
        Create enqueues a job on the "notes" BullMQ queue; notes-worker (a
        separate Python process) processes it and writes to MongoDB. Watch a
        new note go from "pending" to "completed" below.
      </p>

      <form onSubmit={handleCreate} style={{ margin: '1.5rem 0', padding: '1rem', background: '#f7f7f7', borderRadius: '6px' }}>
        <div style={{ marginBottom: '0.75rem' }}>
          <input
            type="text"
            placeholder="Title"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            required
            style={{ width: '100%', padding: '0.5rem', fontSize: '1rem' }}
          />
        </div>
        <div style={{ marginBottom: '0.75rem' }}>
          <textarea
            placeholder="Body"
            value={body}
            onChange={(e) => setBody(e.target.value)}
            rows={3}
            style={{ width: '100%', padding: '0.5rem', fontSize: '1rem' }}
          />
        </div>
        <button
          type="submit"
          disabled={creating}
          style={{ padding: '0.6rem 1.2rem', background: '#007bff', color: 'white', border: 'none', borderRadius: '4px', cursor: creating ? 'not-allowed' : 'pointer' }}
        >
          {creating ? 'Queueing...' : 'Create note'}
        </button>
      </form>

      {error && <p style={{ color: 'red' }}>{error}</p>}

      <ul style={{ listStyle: 'none', padding: 0 }}>
        {notes.map((note) => (
          <li
            key={note.id}
            style={{
              padding: '1rem',
              marginBottom: '0.75rem',
              borderRadius: '6px',
              border: '1px solid #ddd',
              background: note.status === 'pending' ? '#fff8e1' : 'white'
            }}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between' }}>
              <strong>{note.title}</strong>
              <span style={{
                fontSize: '0.75rem',
                padding: '0.15rem 0.5rem',
                borderRadius: '10px',
                background: note.status === 'pending' ? '#ffe082' : '#c8e6c9',
                color: '#333'
              }}>
                {note.status === 'pending' ? 'pending (queued)' : 'completed'}
              </span>
            </div>
            <p style={{ margin: '0.5rem 0 0', color: '#555' }}>{note.body}</p>
          </li>
        ))}
        {notes.length === 0 && <p style={{ color: '#888' }}>No notes yet - create one above.</p>}
      </ul>
    </div>
  );
}

export default NotesApp;
