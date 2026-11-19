const positiveInteger = (value: string | undefined, fallback: number): number => {
  const parsed = Number.parseInt(value ?? '', 10);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
};

export interface AppConfig {
  port: number;
  logLevel: string;
  environment: string;
  version: string;
  faultInjection: boolean;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  return {
    port: positiveInteger(env.PORT, 3000),
    logLevel: env.LOG_LEVEL || 'info',
    environment: env.ENVIRONMENT || env.NODE_ENV || 'development',
    version: env.APP_VERSION || '1.0.0',
    // Enables GET /simulate/error for alerting and dashboard demos. Off by default.
    faultInjection: env.FAULT_INJECTION === 'true'
  };
}
