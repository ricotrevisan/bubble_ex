import Config

config :bubble_ex,
  logs: [
    default_endpoint: "https://bubble.io/appeditor/get_jetstream_logs",
    default_timeout: 30_000,
    default_app_version: "live",
    pool_max_connections: 10,
    pool_timeout: 30_000
  ],
  apps: [
    default_timeout: 10_000,
    max_body_length: 100_000_000
  ]

import_config "#{config_env()}.exs"
