#!/usr/bin/env bash
# deploy-frontend.sh — Build and deploy React app to S3 + invalidate CloudFront
set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CLIENT_DIR="$ROOT_DIR/Client"

S3_BUCKET="${FRONTEND_BUCKET_NAME:?FRONTEND_BUCKET_NAME not set}"
CF_DIST_ID="${CLOUDFRONT_DISTRIBUTION_ID:?CLOUDFRONT_DISTRIBUTION_ID not set}"
VITE_API_BASE_URL="${VITE_API_BASE_URL:?VITE_API_BASE_URL not set}"

# ── Build ──────────────────────────────────────────────────────────────────────
echo "▶ Building frontend..."
cd "$CLIENT_DIR"
npm ci
VITE_API_BASE_URL="$VITE_API_BASE_URL" npm run build

if [ ! -d dist ]; then
  echo "✗ Build failed — dist/ not found"
  exit 1
fi
echo "✓ Build complete"

# ── Deploy ─────────────────────────────────────────────────────────────────────
echo "▶ Syncing to s3://$S3_BUCKET ..."

# HTML — no cache
aws s3 sync dist/ "s3://$S3_BUCKET" \
  --exclude "*" --include "*.html" \
  --cache-control "no-cache, no-store, must-revalidate" \
  --delete

# Hashed assets — immutable
aws s3 sync dist/ "s3://$S3_BUCKET" \
  --exclude "*.html" \
  --cache-control "public, max-age=31536000, immutable" \
  --delete

echo "✓ S3 sync complete"

# ── Invalidate CloudFront ──────────────────────────────────────────────────────
echo "▶ Invalidating CloudFront distribution $CF_DIST_ID ..."
INV_ID=$(aws cloudfront create-invalidation \
  --distribution-id "$CF_DIST_ID" \
  --paths "/*" \
  --query 'Invalidation.Id' --output text)
echo "  Invalidation ID: $INV_ID"
aws cloudfront wait invalidation-completed \
  --distribution-id "$CF_DIST_ID" --id "$INV_ID"
echo "✓ CloudFront invalidation complete"

echo "✅ Frontend deployed successfully"
