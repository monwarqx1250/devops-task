import { buildApp } from './src/app.js';

const { app, config } = buildApp();

const shutdown = async (signal: string): Promise<void> => {
  app.log.info({ signal }, 'shutdown requested');
  try {
    await app.close();
    process.exit(0);
  } catch (error) {
    app.log.error({ err: error }, 'graceful shutdown failed');
    process.exit(1);
  }
};

process.once('SIGTERM', () => void shutdown('SIGTERM'));
process.once('SIGINT', () => void shutdown('SIGINT'));

try {
  await app.listen({ host: '0.0.0.0', port: config.port });
  app.log.info({
    environment: config.environment,
    port: config.port,
    version: config.version
  }, 'server started');
} catch (error) {
  app.log.error({ err: error }, 'server failed to start');
  process.exit(1);
}
