import { serve } from '@hono/node-server'
import { Hono } from 'hono'

const app = new Hono()

app.get('/', (c) => c.json({ message: 'Hello from Hono', service: 'hono' }))
app.get('/api/hello', (c) => c.json({ message: 'Hello from Hono' }))
app.get('/healthz', (c) => c.json({ ok: true }))

serve({ fetch: app.fetch, port: 3000 })
