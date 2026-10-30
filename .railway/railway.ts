import { defineRailway, github, preserve, project, service } from "railway/iac";

export const partial = "wallop";

export default defineRailway(() => {
  const wallop = service("wallop", {
    source: github("electric-lump-software/wallop", { branch: "main" }),
    build: {
      builder: "DOCKERFILE",
      dockerfilePath: "Dockerfile",
    },
    deploy: {
      restartPolicyType: "ON_FAILURE",
      restartPolicyMaxRetries: 5,
      drainingSeconds: 150,
      overlapSeconds: 0,
    },
    start: "/usr/local/bin/inshape --allowlist /etc/wallop/secrets.allow -- /app/bin/migrate_and_start",
    healthcheck: "/health",
    healthcheckTimeout: 300,
    env: {
      AWS_ACCESS_KEY_ID: preserve(),
      AWS_DEFAULT_REGION: preserve(),
      AWS_ENDPOINT_URL: preserve(),
      AWS_S3_BUCKET_NAME: preserve(),
      AWS_SECRET_ACCESS_KEY: preserve(),
      DATABASE_URL: preserve(),
      GOTENBERG_URL: preserve(),
      INFISICAL_ENV: preserve(),
      INFISICAL_PATHS: preserve(),
      INFISICAL_PROJECT_ID: preserve(),
      INFISICAL_UNIVERSAL_AUTH_CLIENT_ID: preserve(),
      INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET: preserve(),
      MIGRATION_DATABASE_URL: preserve(),
      PHX_HOST: preserve(),
      PORT: preserve(),
      PROOF_PDF_CACHE_ENABLED: preserve(),
      REDIS_URL: preserve(),
      VERIFY_BLOCK_ANCHOR_MODE: preserve(),
    },
  });
  return project("Wallop", {
    resources: [wallop],
  });
});
