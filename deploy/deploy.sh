mix deps.get &&
mix local.hex --force &&
mix hex.publish --yes &&
mix clean &&
mix deps.clean --all
