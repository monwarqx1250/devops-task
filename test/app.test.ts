import { afterEach, describe, expect, it } from 'bun:test';
import { buildApp } from '../src/app.js';

describe('DevOps assessment service', () => {
  let app: Awaited<ReturnType<typeof buildApp>>['app'] | undefined;

  afterEach(async () => {
    if (app) await app.close();
  });

  it('returns the configured greeting and version', async () => {
    const context = buildApp({ APP_VERSION: '2.4.1', LOG_LEVEL: 'silent' });
    app = context.app;
    const response = await context.app.inject({ method: 'GET', url: '/' });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      message: 'Hello from DevOps Task!',
      status: 'running',
      version: '2.4.1'
    });
  });

  it('exposes a healthy liveness/readiness response', async () => {
    const context = buildApp({ LOG_LEVEL: 'silent' });
    app = context.app;
    const response = await context.app.inject('/health');

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ status: 'ok' });
  });

  it('serves the /metrics endpoint in Prometheus text format', async () => {
    const context = buildApp({ LOG_LEVEL: 'silent' });
    app = context.app;
    const response = await context.app.inject('/metrics');

    expect(response.statusCode).toBe(200);
    expect(response.headers['content-type']).toContain('text/plain');
  });

  it('counts requests by route template and status code', async () => {
    const context = buildApp({ LOG_LEVEL: 'silent' });
    app = context.app;
    await context.app.inject('/');
    await context.app.inject('/does-not-exist');
    const body = (await context.app.inject('/metrics')).body;

    expect(body).toContain('http_requests_total{method="GET",route="/",status_code="200"} 1');
    expect(body).toContain('http_requests_total{method="GET",route="unmatched",status_code="404"} 1');
    expect(body).toContain('http_request_duration_seconds_bucket');
    expect(body).not.toContain('route="/metrics"');
  });

  it('counts 5xx responses as errors', async () => {
    const context = buildApp({ LOG_LEVEL: 'silent' });
    app = context.app;
    context.app.get('/boom', async () => {
      throw new Error('boom');
    });
    const response = await context.app.inject('/boom');
    const body = (await context.app.inject('/metrics')).body;

    expect(response.statusCode).toBe(500);
    expect(body).toContain('http_request_errors_total{method="GET",route="/boom",status_code="500"} 1');
  });

  it('only registers /simulate/error when FAULT_INJECTION=true', async () => {
    const off = buildApp({ LOG_LEVEL: 'silent' });
    app = off.app;
    expect((await off.app.inject('/simulate/error')).statusCode).toBe(404);
    await off.app.close();

    const on = buildApp({ LOG_LEVEL: 'silent', FAULT_INJECTION: 'true' });
    app = on.app;
    expect((await on.app.inject('/simulate/error')).statusCode).toBe(500);
  });

  it('exposes default process metrics', async () => {
    const context = buildApp({ LOG_LEVEL: 'silent' });
    app = context.app;
    const body = (await context.app.inject('/metrics')).body;

    expect(body).toContain('process_cpu_seconds_total');
    expect(body).toContain('process_resident_memory_bytes');
  });
});
