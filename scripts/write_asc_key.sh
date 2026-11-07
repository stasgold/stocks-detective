#!/usr/bin/env bash
# Writes the App Store Connect API key from secrets to $RUNNER_TEMP and exports
# KEY_PATH plus trimmed IDs to $GITHUB_ENV. Accepts the .p8 pasted as-is, base64,
# with literal \n, CRLF, or just the key body.
set -e
# Trim stray spaces/newlines that often sneak in when pasting secrets.
KEY_ID=$(printf '%s' "$ASC_KEY_ID" | tr -d '[:space:]')
ISSUER=$(printf '%s' "$ASC_ISSUER_ID" | tr -d '[:space:]')
TEAM=$(printf '%s' "$APPLE_TEAM_ID" | tr -d '[:space:]')
KEY_PATH="$RUNNER_TEMP/AuthKey_$KEY_ID.p8"
RAW=$(printf '%s' "$ASC_KEY_P8" | tr -d '\r')

if printf '%s' "$RAW" | grep -q "BEGIN PRIVATE KEY"; then
  # Pasted .p8 contents (also handles literal \n instead of real newlines).
  printf '%b\n' "$RAW" > "$KEY_PATH"
else
  DECODED=$(printf '%s' "$RAW" | tr -d '[:space:]' | base64 --decode 2>/dev/null | tr -d '\000' || true)
  if printf '%s' "$DECODED" | grep -q "BEGIN PRIVATE KEY"; then
    printf '%s\n' "$DECODED" > "$KEY_PATH"      # base64 of the whole .p8 file
  else
    {                                        # just the key body, without header lines
      echo "-----BEGIN PRIVATE KEY-----"
      printf '%s' "$RAW" | tr -d '[:space:]' | fold -w 64
      echo
      echo "-----END PRIVATE KEY-----"
    } > "$KEY_PATH"
  fi
fi

echo "Key ID length: ${#KEY_ID} (expected 10)"
echo "Issuer ID length: ${#ISSUER} (expected 36)"
echo "Team ID length: ${#TEAM} (expected 10)"
echo "Key file: $(wc -l < "$KEY_PATH" | tr -d ' ') lines, $(wc -c < "$KEY_PATH" | tr -d ' ') bytes"
if openssl pkey -in "$KEY_PATH" -noout 2>/dev/null; then
  echo "Private key parses OK"
else
  echo "::error::ASC_KEY_P8 is not a valid private key. Paste the full contents of the AuthKey_XXXX.p8 file, including the BEGIN/END lines."
  exit 1
fi
chmod 600 "$KEY_PATH"
{
  echo "KEY_PATH=$KEY_PATH"
  echo "ASC_KEY_ID=$KEY_ID"
  echo "ASC_ISSUER_ID=$ISSUER"
  echo "APPLE_TEAM_ID=$TEAM"
} >> "$GITHUB_ENV"
