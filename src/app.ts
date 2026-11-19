import { hostname } from 'node:os';

import Fastify from 'fastify';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { collectDefaultMetrics, Counter, Histogram, Registry } from 'prom-client';

import { loadConfig } from './config.js';

export interface AppContext {
  app: FastifyInstance;
  config: ReturnType<typeof loadConfig>;
}

// Route template (e.g. "/users/:id") keeps label cardinality bounded.
const routeOf = (request: FastifyRequest): string =>
  request.routeOptions.url ?? 'unmatched';

export function buildApp(env: NodeJS.ProcessEnv = process.env): AppContext {
  const config = loadConfig(env);

  const app = Fastify({
    logger: {
      level: config.logLevel,
      // Emit "level":"info" instead of pino's numeric "level":30 so Loki can
      // use it directly as a label.
      formatters: {
        level: (label) => ({ level: label })
      },
      // ISO-8601 timestamps are readable in raw logs and parse cleanly.
      timestamp: () => `,"time":"${new Date().toISOString()}"`,
      // Attached to every log line.
      base: {
        hostname: hostname(),
        environment: config.environment,
        version: config.version
      }
    }
  });

  const registry = new Registry();

  // Process/runtime metrics: CPU, resident memory, heap, event-loop lag, GC.
  collectDefaultMetrics({ register: registry });

  const httpRequestsTotal = new Counter({
    name: 'http_requests_total',
    help: 'Total HTTP requests served',
    labelNames: ['method', 'route', 'status_code'] as const,
    registers: [registry]
  });

  const httpRequestErrors = new Counter({
    name: 'http_request_errors_total',
    help: 'Total HTTP requests that ended in a 5xx response',
    labelNames: ['method', 'route', 'status_code'] as const,
    registers: [registry]
  });

  const httpRequestDuration = new Histogram({
    name: 'http_request_duration_seconds',
    help: 'HTTP request latency in seconds',
    labelNames: ['method', 'route', 'status_code'] as const,
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
    registers: [registry]
  });

  app.addHook('onResponse', async (request, reply) => {
    const route = routeOf(request);

    if (route === '/metrics') return;

    const labels = {
      method: request.method,
      route,
      status_code: String(reply.statusCode)
    };

    httpRequestsTotal.inc(labels);
    httpRequestDuration.observe(labels, reply.elapsedTime / 1000);

    if (reply.statusCode >= 500) {
      httpRequestErrors.inc(labels);
    }
  });

  app.get('/', async () => ({
    message: 'Hello from DevOps Task!',
    status: 'running',
    version: config.version
  }));

  app.get('/health', async () => ({
    status: 'ok'
  }));

  if (config.faultInjection) {
    // Demo-only route used to produce a real 5xx spike (see README). Never
    // registered unless FAULT_INJECTION=true.
    app.get('/simulate/error', async () => {
      throw new Error('simulated failure (FAULT_INJECTION=true)');
    });
  }

  app.get('/metrics', async (_request, reply) => {
    reply.header('Content-Type', registry.contentType);
    return registry.metrics();
  });

  return { app, config };
}
