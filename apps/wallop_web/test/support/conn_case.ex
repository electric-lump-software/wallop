defmodule WallopWeb.ConnCase do
  @moduledoc "ExUnit case template for tests requiring a Phoenix conn."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import WallopWeb.ConnCase
      import WallopCore.TestHelpers

      @endpoint WallopWeb.Endpoint
    end
  end

  setup tags do
    WallopCore.DataCase.setup_sandbox(tags)

    # Rate-limit counters live in the RateLimiter's ETS table for the life of
    # the node. Every test connects from 127.0.0.1, so without this each
    # test would inherit the previous test's budget and
    # trip the per-IP cap. Clearing here keeps tests independent.
    #
    # INVARIANT: this reset is global, not per-test. Any module that asserts on
    # accumulated rate-limit state — anything expecting a 429 — MUST be
    # `async: false`, or a concurrent module's setup can wipe its counter
    # mid-test and it will see a 200 instead. ExUnit runs async modules before
    # sync ones, so `async: false` is sufficient to keep them apart. Every
    # module asserting 429 is currently sync; keep it that way.
    WallopWeb.RateLimiter.reset()

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
