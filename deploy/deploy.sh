mix deps.get &&
mix local.hex --force &&
mkdir -p ~/.hex/ &&
echo "$HEX_ENCRYPTED_TOKEN" >> ~/.hex/hex.config &&
echo "$HEX_LOCAL_PASSPHRASE" | mix hex.publish  --no-confirm &&
mix clean &&
mix deps.clean --all