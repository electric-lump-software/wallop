exclude = if System.get_env("REDIS_URL"), do: [], else: [:redis]
ExUnit.start(exclude: exclude)
